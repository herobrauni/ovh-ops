# InfiniDysk 2.x test instance and cutover runbook

> **Status 2026-11-20: Phase A applied** (clone PVCs, cloned DB, v2 app deployed
> as `media/infinidysk-v2` next to the live 1.x backend). Phase B/C are the
> grading steps; the 1.x backend stays authoritative until they pass.

Working record for evaluating **InfiniDysk 2.x** (`ghcr.io/infinidysk/infinidysk-next`,
Rust rewrite, 2.0.0-beta.N) as a replacement for the 1.x backend in
`media/infinidysk`. Manifests live in `kubernetes/apps/media/infinidysk-v2/`;
durable behavioural findings belong in `docs/agents/media.md`, not here.

## Decisions

1. **rclone sidecars + WebDAV stay, the built-in FUSE mount stays off**
   (`INFINIDYSK__MOUNT__FUSE=false`). A FUSE mount only exists in one pod's host
   namespace: consumers would have to read a hostPath that exists on this pod's
   node only, so ten pods need node pinning and the backend pod becomes one
   shared mount provider and failure domain. Per-consumer rclone sidecars keep
   the blast radius per pod, as today.
2. **The instance keeps its own name.** Cutover = repointing the *arrs'
   download client and the consumers' `RCLONE_CONFIG_INFINIDYSK_URL` at the v2
   Service. Nothing is renamed, so a rollback is the reverse edit.
3. **Throwaway data.** Both PVCs are one-time CSI clones of the live backend's
   volumes; the v2 store itself is SQLite in `/config` (moving it to PostgreSQL
   is optional and can wait until the cutover is decided).
4. **No public route.** The UI is reached by port-forward; a hostname would drag
   in the OIDC role-model question (2.x dropped `OIDC_ADMIN_CLAIM`, every SSO
   user is an admin) before the backend itself is graded.

## Phase A — data clones (done)

Applied by Flux from `app/pvc.yaml` + `app/volumesnapshot.yaml`
(RBD snapshot of `infinidysk`, CephFS snapshot of `symlinks`; both CSI clone
paths verified on this cluster).

The **database** clone is a manual one-off, because it is data, not a resource:

```sh
# superuser creates the DB owned by the app role…
kubectl exec -n dbms postgres18-1 -c postgres -- sh -c \
  "PGPASSWORD='<super>' psql -h 127.0.0.1 -U postgres -c 'create database infinidysk_v2 owner infinidysk'"
# …and the app role copies the schema + data into it.
kubectl exec -n dbms postgres18-1 -c postgres -- sh -c \
  "PGPASSWORD='<infinidysk>' pg_dump -h 127.0.0.1 -U infinidysk -d infinidysk \
   | PGPASSWORD='<infinidysk>' psql -q -h 127.0.0.1 -U infinidysk -d infinidysk_v2"
```

Credentials: `INIT_POSTGRES_SUPER_PASS` / `INIT_POSTGRES_PASS` in
`media/infinidysk-initdb-secret`. Refresh the clone (e.g. before the real
cutover) with `drop database infinidysk_v2` + the two commands above.

Re-cloning the volumes: bump the snapshot names in `app/volumesnapshot.yaml`,
delete both claims, reconcile — the next pod start re-runs the 1.x import.
**Never** point this instance at the live `symlinks` claim: 2.x runs
"remove dead library links" / "remove unlinked files" maintenance against its
library dir and would prune the production farm.

## Phase B — grade the import

```sh
kubectl -n media port-forward pod/infinidysk-v2-<hash> 3000:3000
```

Log in with the **imported** local admin account (`Accounts.Type = 1`), not SSO.
Checklist, compared against the 1.x backend:

- [ ] 5 providers, with `priority` derived from `Type 3` (BackupOnly) and
      `backbone` from `StorageGroup`; connection state per provider OK.
- [ ] 4 arr instances (2 Sonarr, 2 Radarr) — 2.x needs a `profile` per instance,
      check whether the import sets it and whether Readarr-style rejection fires.
- [ ] `mount.dir` = `/aio/remote/infinidysk` (imported from `rclone.mount-dir`);
      `/aio/symlinks` as library dir.
- [ ] SAB categories `other,radarr,radarr4k,sonarr,sonarr4k,nonplex,books`,
      manual category `other`, symlink import strategy.
- [ ] Import report (startup log / `import-report`): note every setting it could
      **not** carry over, especially `QueueRules` (2.x hardcodes queue actions)
      and `api.ensure-importable-video` (no 2.x switch — the `books` category
      relies on it being off).
- [ ] Library: `DavItems` ≈ 15k in the clone, `.ids` resolution works through the
      loopback rclone mount of the app pod (`/aio/remote/infinidysk`).
- [ ] `/config/repair-segments` (103 MB, 199 `Par2RepairJobs`) is inert — 2.x has
      no PAR2 patch store; its "repair" is health recheck + Arr replacement.
- [ ] `NZBDAV_CONFIG__*` overlay is a first-start-only input: after the import,
      **remove** `DATABASE_PROVIDER` / `DATABASE_CONNECTION_STRING` from the
      HelmRelease and replace the 1.x overlay with the durable `INFINIDYSK__*`
      (snake_case) settings surface.

## Phase C — functional tests (1.x untouched)

1. **Mount + playback through v2**: point `media-debug`'s
   `RCLONE_CONFIG_INFINIDYSK_URL` at `http://infinidysk-v2.media.svc.cluster.local:3000/`
   and read a known-good release (2.x serves WebDAV on the same port as the UI).
2. **Grab through v2**: repoint **one** *arr (start with `radarr`) at the same
   URL, add the release client at category `radarr` and grab a title. The SAB
   key is identical (imported), so nothing else in the client changes.
3. **Watch the three known regressions** instead of asserting they are fine:
    - compressed-RAR / "matched by series ID" classes: 2.x's queue rules are
      fixed, so measure stuck imports and blocklist behaviour;
    - `books`/`other` payloads with no importable media;
    - health: re-grab rate and provider byte spend vs 1.x's PAR2 gap repair
      (`repair.par2-*` settings and the patch store do not exist in 2.x).
4. **Supporting apps**: `infinidysk-sync-helper` (SAB `mode=history` on 3000) and
   the Bazarr sidecars (WebDAV reads on 3000).
5. **Metrics**: 2.x serves `/metrics` behind the **admin API key**
   (`metrics.prometheus`), unlike 1.x's unauthenticated `/metrics`. A
   ServiceMonitor for v2 needs a `bearerTokenSecret`/header credential.

## Phase D — cutover (only if C passes)

1. Stop the four *arrs' imports (pause indexers or just the client), stop
   `infinidysk-sync-helper`.
2. Freeze 1.x: scale `infinidysk` to 0 (clean snapshot), then refresh the v2
   data: re-snapshot the PVCs, re-clone, re-dump the database (Phase A).
3. Let v2 import the fresh clones, re-run the Phase B checklist.
4. Repoint `RCLONE_CONFIG_INFINIDYSK_URL` in all consumers (9 sidecars +
   sync-helper) and the *arr download clients to `infinidysk-v2.media.svc…:3000`.
5. Rollback at any point: scale 1.x back up, repoint the URL/clients back. The v2
   instance never writes to the live farm or the live database, so 1.x state is
   untouched (a `--force` reconcile of the affected HelmReleases is all it takes).

## Known gaps to keep in view (upstream, not ours to fix)

| Gap                                                         | Impact here                                                                                                      |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| No PAR2 gap repair                                          | More Arr re-grabs for damaged releases; the 103 MB patch store has no successor                                  |
| `QueueRules` not configurable                               | The compressed-RAR class and our "matched by series ID" rule rely on hardcoded 2.x behaviour                     |
| `api.ensure-importable-video` / per-category article checks | One global `health.import_check_percent`; the `books` category may fail imports again                            |
| `OIDC_ADMIN_CLAIM` dropped                                  | Every SSO user is admin; the `Platform`-group gate must move to authentik group binding                          |
| Indexers/search/Warden/Preflight/Watchtower                 | Not planned in 2.x — unused here (no `indexers.*`, `IndexerApiHits` = 0, `warden_entries` = 0)                   |
| Env prefix + JSON shape change                              | The durable surface becomes `INFINIDYSK__*` with snake_case JSON; `NZBDAV_CONFIG__*` is ignored after the import |
| Settings `id` fields                                        | 2.x wants fixed UUIDs for providers/arrs, or stats and quota usage reset every restart                           |
