# Plex trash sweep for the zurg-backed libraries (design — not implemented)

Written 2026-09-30 when zurg's Plex integration was wired up (`media/zurg` config ExternalSecret).
Parked deliberately: the cluster currently runs `plex_settings_policy: guard`, which means zurg
turns Plex's `autoEmptyTrash` off (the mount-blip data-loss guard) and nothing collects Plex's
trash afterwards. Entries tombstoned by *arr cleanup (a `__magic__` DELETE hides a release, the
next scan parks it in trash) accumulate until someone hits *Empty Trash* in the Plex UI by hand.
This doc is the plan for automating that safely. If it gets implemented, delete this paragraph.

## Why zurg's native sweep cannot run here

zurg has a built-in sweep (`plex_trash_sweep_every_mins`, default: hourly when nothing else is
emptying the trash). It is a database surgeon: it reads Plex's SQLite directly, removes one entry
at a time, snapshots the database first, caps each pass at 50 removals / 10% of the trash, and
gives entries a 14-day grace period before removal. It cannot run in this cluster for three
compounding reasons:

1. **It needs the database file in zurg's own filesystem.** `plex_database_path` is "driven by an
    explicit path and stays off until you set one" — there is no HTTP/RPC mode. The file is
    `.../Plug-in Support/Databases/com.plexapp.plugins.library.db` on plex's `/config` PVC.
2. **That PVC is RWO ceph-block.** Sharing an RWO block volume into the zurg pod is only possible
    by pinning both pods to the same node (shared volume attachment) — fragile scheduling coupling
    for a convenience feature, and it breaks again on any reschedule.
3. **Two pods, two SQLite handles, one live WAL database, over network block storage.** zurg's own
    docs warn that a stock `sqlite3` "can fail on, or damage, this database" and ship a
    Plex-specific binary for a reason. The supported topology is zurg running on the Plex *host*;
    pods do not give us that.

So the sweep has to be reimplemented at the cluster level, against Plex's API instead of its
database.

## Design: health-gated scan-then-empty sidecar in the plex pod

A small sidecar container in the `plex` deployment. It must live in the plex pod because the
whole safety argument depends on checking **the exact filesystem view Plex scans** — a separate
CronJob pod cannot see it (the zurg mount is a per-pod rclone sidecar mount over a node-local
hostPath), and `kubectl exec` into plex from a CronJob would add RBAC for no extra safety.

Daily at 04:00 Europe/Paris (k8tz injects `TZ`; the container's `date` is already Paris time):

1. **Health gate.** `test -r` a file under each zurg-backed library root as the sidecar sees it:
    `/aio/remote/zurg/__magic__/tv` and `/aio/remote/zurg/__magic__/movies` must exist and read.
    zurg's DAV endpoint being up is *not* sufficient — the rclone sidecar's mount is the thing
    that can be wedged while zurg answers fine. Any failure: log, skip, retry next day.
2. **Scan the zurg-backed sections.** `GET /library/sections` (token-authed), keep sections whose
    `Location path=` starts with `/aio/remote/zurg/`, then `GET /library/sections/{key}/refresh`
    for each. This is the cluster equivalent of zurg's "never remove an entry that still has a
    file": anything still present on the mount is re-added by the scan *before* the trash is
    touched, so a transient blip that parked entries days ago cannot purge live content.
3. **Wait for the scans.** Poll `GET /activities` until no `library.update.section` activity
    remains (two consecutive quiet polls, ~2 min apart), hard timeout ~45 min. On timeout: skip
    the emptying — a scan still running means the library state is not settled.
4. **Empty the trash, scoped.** `PUT /library/sections/{key}/emptyTrash` — the documented
    endpoint (developer.plex.tv "Empty section trash"; the same call the Plex Web UI's
    *Manage → Empty Trash* button makes; plexapi uses PUT), with the standard Plex token
    header. Only for the sections matched in step 2 — the altmount-backed libraries keep
    their own trash semantics untouched.
5. **State.** A run-once-per-day marker in an emptyDir (`/tmp/last-sweep`) keyed by date, so a
    sidecar restart cannot double-run; heartbeat file touched every loop tick for the liveness
    probe.

Fail-safe direction everywhere: any gate, scan, wait, or API failure ends the run with the trash
untouched.

### Deltas vs zurg's native sweep (accepted, documented)

| zurg sweep | this design | why acceptable |
| --- | --- | --- |
| 14-day per-entry grace before removal | none — entries parked *today* get emptied today | the pre-empty scan re-adds anything whose file still exists; age only mattered because zurg checks files lazily |
| 50 removals / 10% of trash per pass | emptyTrash is all-at-once, per section | the caps guard against a mass-deletion misjudgment; the health gate + scan-then-empty pair is the equivalent judgment here |
| SQLite snapshot before removing | none | the sweep never touches the database; Plex's own nightly `ButlerTaskBackupDatabase` stays on (zurg's `guard` policy keeps it on) and is the recovery path |
| Only from a mount that reads at that moment | step 1, same check, from inside the plex pod | — |
| Never removes an entry that still has a file | step 2: scan re-adds everything still present first | — |

### What it deliberately does not do

- Does not touch `autoEmptyTrash` — that stays off. Two collectors ("zurg or Plex empties the
    trash") is the exact disagreement zurg's docs warn about; there is exactly one collector here.
- Does not empty the altmount-backed sections' trash. Their deletions go through decypharr/
    altmount and are a separate decision.
- Does not run on a schedule tighter than daily. zurg's hourly cadence buys nothing once the
    trash is being collected at all.

## Implementation checklist

- `kubernetes/apps/media/plex/app/externalsecret.yaml` (new): syncs the Plex server token from
    the Infisical `/sync-helper/` folder (the same credential nzbdav-sync-helper and zurg already
    consume) → Secret `plex-sweep-secret`. Create/verify the Infisical key *before* the ES lands —
    a missing `remoteRef` fails the whole ExternalSecret.
- `kubernetes/apps/media/plex/ks.yaml`: add `dependsOn: infisical` (namespace
    `external-secrets`) — plex currently has no secrets, so the dependency is not declared yet.
- Script as ConfigMap (`trash-sweep.yaml`), following the `nzbdav-sync-helper` pattern: busybox
    (`ghcr.io/home-operations/busybox`, digest-pinned), POSIX sh, `wget` against
    `http://localhost:32400` (in-pod — no Service dependency), XML parsed with `sed`/`grep`
    (Plex answers XML without an `Accept: application/json` header; no jq in busybox).
- Sidecar container in `kubernetes/apps/media/plex/app/helmrelease.yaml`
    (`controllers.plex.containers.trash-sweep`): mounts the existing pod-level `zurg` hostPath
    volume (read-only view is fine — it only `test`s paths), the script ConfigMap, an emptyDir at
    `/tmp` for state. `readOnlyRootFilesystem: true`, runs as the pod's 1000:1000, requests
    `10m/16Mi`, limits `100m/64Mi`. Liveness: `find /tmp/heartbeat -mmin -30` (loop ticks every
    5 min; a stale heartbeat means the loop is wedged).
- First run lands ~10 min after deploy (initial settle sleep), then daily at 04:00.

## Verification

1. `kubectl -n media logs deploy/plex -c trash-sweep` — gate result, sections matched, scan wait,
    emptyTrash per section.
2. Before/after: Plex Web → each zurg-backed library → trash item count (or
    `GET /library/sections/{key}/all?includeDeleted=1` before, spot-check after).
3. Watch-state spot check on one tombstoned-then-re-added title (playback progress survives
    re-adds matched by GUID; confirm on a real item once).
4. Negative test: `kubectl -n media exec deploy/plex -c trash-sweep -- rm -rf
    /aio/remote/zurg/__magic__/tv` is NOT a valid test (destroys nothing but fakes a gate
    failure only if permissions allow) — instead confirm the gate by checking the log line when
    zurg is scaled to zero for a minute at a non-04:00 time and a manual run is triggered by
    deleting `/tmp/last-sweep`.

## Rollback

Remove the sidecar container + ConfigMap + ExternalSecret and the `ks.yaml` dependency. Nothing
else references them; zurg's `guard` policy and manual trash emptying keep working exactly as
today.
