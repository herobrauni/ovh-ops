# InfiniDysk 2.x — backend and cutover runbook

> **Status 2026-11-20: CUTOVER COMPLETE.** `media/infinidysk-v2` serves the canonical
> `https://infinidysk.480p.com` (2.0.0-beta.10, Rust, PostgreSQL store `infinidysk_v2`, real
> `symlinks` farm, full provider allowances, OIDC via authentik, `/metrics` scraped with its admin
> key). The 1.x app is **disabled**: its Kustomization is commented out of
> `media/kustomization.yaml` and Flux garbage-collected it — the data a rollback needs lives in the
> VolumeSnapshot `media/infinidysk-v1-final`, the PostgreSQL database `infinidysk` and the kopiur
> repository. Read "Rollback" before touching provider connections.

Working record for evaluating **InfiniDysk 2.x** (`ghcr.io/infinidysk/infinidysk-next`,
Rust rewrite, 2.0.0-beta.N) as a replacement for the 1.x backend. Manifests live in
`kubernetes/apps/media/infinidysk-v2/`; durable behavioural findings belong in
`docs/agents/media.md`, not here.

## Rollback (1.x is disabled, its data kept)

1. **Free provider connections first.** v2 holds the FULL plan now, so v1 must not come up at 80 %
   next to it (eweka would be 90/50). Scale `infinidysk-v2` to 0 — or cut its providers back to the
   20 % numbers — before starting v1.
2. **Restore v1's config volume** from `VolumeSnapshot media/infinidysk-v1-final` (taken at the
   cutover; it holds `blobs/`, which a re-import needs) into a PVC named `infinidysk`
   (`dataSourceRef` → VolumeSnapshot, 30Gi, `ceph-block`). Its PostgreSQL database `infinidysk` was
   never Flux-managed and is untouched; the kopiur repository holds older snapshots of the same
   volume.
3. **Re-enable the app**: uncomment `./infinidysk/ks.yaml` in `media/kustomization.yaml` and re-add
   the `components/dnsendpoint` line to that `ks.yaml` (the canonical host now belongs to the v2
   manifest — either drop v2's `httproute.yaml`/`dnsendpoint.yaml` or keep v1 on a different host).
4. **Revert the consumer commit**: every `RCLONE_CONFIG_INFINIDYSK_URL` back to
   `http://infinidysk.media.svc.cluster.local:8080/` and the sync-helper's `SAB_URL` back to
   `:3000`, then `flux reconcile kustomization cluster-apps --with-source`.
5. **Repoint the four \*arr download clients** to `infinidysk.media.svc.cluster.local:3000`
   (runtime state, not Git — `PUT /api/v3/downloadclient/{id}`).
6. `flux reconcile helmrelease -n media <app> --force` for any consumer whose HelmRelease had rolled
   back earlier.

Nothing 2.x wrote is needed for that: it only ever adds `.ids` blobs and `completed-symlinks`
entries, which 1.x simply ignores. Its store database (`infinidysk_v2`) can be dropped.

## Cutover postmortem — what broke and why

1. **The import needs its own provider list.** The import builds a _separate_
   provider client from the 1.x settings, so with the `NZBDAV_CONFIG__*` block
   already removed it had **no providers** and skipped 2081 files with
   `segment sizes unknown: provider unavailable`. The recipe block in
   "Re-import recipe" must be present for the whole import, not just for the
   reader database.
2. **Flip consumers only after the import finishes.** 2.x answers WebDAV with
   `503` while importing, so sidecar probes fail; two HelmReleases
   (`infinidysk-sync-helper`, `silo`) exhausted their progress deadline and
   rolled back to the old values — the pods kept mounting the 1.x backend
   (dead) while Git said v2. `flux reconcile helmrelease … --force` recovers.
3. **The download client and the rclone mount must move together.** A release
   imported by 2.x lives only in 2.x's `.ids` tree; an Arr still mounting the
   1.x tree sees `completed-symlinks/<category>/<release>` as missing and never
   imports.
4. **Prometheus needs an ingress rule per backend.** The v2 CNP allowlist had to
   list the Prometheus pod again, or the scrape hangs until the deadline
   (`context deadline exceeded`) instead of failing fast.
5. **The 1.x leftovers return with every re-clone of `/config`** (they live in the 1.x volume):
   after an import, delete `blobs/`, `db.sqlite*`, `repair-segments/`, `warden.db`,
   `usenet-migration.db`, `data-protection/`, `session.key`, `rclone/`, `backups/` — `/config` goes
   from 7.6 GB back to ~400 MB (metrics only). `/api/v1/upgrade/leftovers/scan` then reports every
   item `missing` and the "1.x data" panel disappears.
6. **A blueprint edit is not applied by merging it.** The ConfigMap reached the worker's mounted
   files, but the watcher did not re-apply it: force it with
   `apply_blueprint.send_with_options(args=(b.pk,), rel_obj=b)` and verify the _effect_ (application
   and provider lists, redirect URIs), not just `status: successful`. A mismatch here only shows up
   at the `/authorize` step, i.e. as `invalid redirect_uri` for the user.
7. **`components/dnsendpoint` derives the host from `${APP}`**, so publishing the canonical
   `infinidysk.480p.com` from an app still named `infinidysk-v2` needs an explicit DNSEndpoint — keep
   the `dns.scope` label _and_ annotation pair (external-dns filters on the label).

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

Databases (two, both owned by the `infinidysk` role, `LC_COLLATE 'C'` like the rest of the
cluster) are a manual one-off, because they are data, not resources:

| Database             | Role                                                                                     |
| -------------------- | ---------------------------------------------------------------------------------------- |
| `infinidysk_v1clone` | read-only **import source**: a `pg_dump` copy of the 1.x `infinidysk`                    |
| `infinidysk_v2`      | the 2.x **store**, created EMPTY (2.x has its own schema and refuses a non-empty target) |

```sh
# superuser creates both, owned by the app role…
kubectl exec -n dbms postgres18-1 -c postgres -- sh -c \
  "PGPASSWORD='<super>' psql -h 127.0.0.1 -U postgres -c 'create database infinidysk_v1clone owner infinidysk'"
kubectl exec -n dbms postgres18-1 -c postgres -- sh -c \
  "PGPASSWORD='<super>' psql -h 127.0.0.1 -U postgres -c 'create database infinidysk_v2 owner infinidysk'"
# …and the app role copies the schema + data into the clone.
kubectl exec -n dbms postgres18-1 -c postgres -- sh -c \
  "PGPASSWORD='<infinidysk>' pg_dump -h 127.0.0.1 -U infinidysk -d infinidysk \
   | PGPASSWORD='<infinidysk>' psql -q -h 127.0.0.1 -U infinidysk -d infinidysk_v1clone"
```

Credentials: `INIT_POSTGRES_SUPER_PASS` / `INIT_POSTGRES_PASS` in
`media/infinidysk-initdb-secret`. Refresh before a rehearsal: `drop database infinidysk_v2` (the
store) and re-create it empty, then re-dump into the clone — **not** the other way round.

`INFINIDYSK_DATABASE_URL` (PostgreSQL, from the secret) is the durable switch, so the app never
manages its own database: no `/config/database.toml`, no Settings > System > Database migration.
**It has ONE underscore** — the `INFINIDYSK__*` (double) namespace is the _settings_ overlay, so
`INFINIDYSK__DATABASE_URL` is read as the settings path `database.url`, found unknown, and silently
ignored: the app then falls back to `/config/database.toml` → default SQLite and tries to re-import
the 1.x install (which fails loudly on `/config/db-contract.json`). Every other variable in this app
is double-underscore, so this one is the trap.
The import writes into whichever store is current, which is why the empty PostgreSQL store is
filled directly (no in-app SQLite → PostgreSQL move). Expect ~15–30 min for that import instead of
~7 min, because ~2 GB of NZB blobs go through the target's WAL.

Re-cloning the volumes: bump the snapshot names in `app/volumesnapshot.yaml`,
delete both claims, reconcile — the next pod start re-runs the 1.x import.
**Never** point this instance at the live `symlinks` claim: 2.x runs
"remove dead library links" / "remove unlinked files" maintenance against its
library dir and would prune the production farm.

## Phase B — grade the import

**Result of the 2026-11-20 rehearsal (beta.10):** import completed in ~7 min for 7281
directories / 7738 files / 5687 NZBs (the 53 MB PG database is staged into
`/config/infinidysk.sqlite` first), 14 files skipped (`/api/v1/upgrade/report` has the per-file
reasons). Carried over correctly:

- providers, mapped onto 2.x's **catalog profiles + backbones + priority** (`frugal-bonus` and
  `blocknews` became level 1, i.e. asked only after level 0 misses) with our connection counts;
- all four arr instances, with `profile` (`sonarr`/`radarr`) **derived** from the 1.x instance type,
  confirmed reachable by `/api/v1/arr/status` (each shows the `InfiniDysk` download client);
- `mount.dir` = `/aio/remote/infinidysk`, `imports.library_dirs` = `/aio/symlinks`, symlink strategy,
  SAB API key, WebDAV user, `queue.concurrency` = 3 (from `queue.worker-count`), STRM key;
- library health after import: **7579 healthy / 3 degraded / 156 ignored** (`/api/v1/health/summary`).

Not carried over (the report lists them verbatim): `api.addurl-trusted-hosts`,
`api.article-existence-check-mode`, `api.ensure-article-existence-categories`,
`api.ensure-importable-video`, `api.nzb-backup-enabled`, `api.nzb-backup-retention-days`,
`arr.health-enabled`, `backup.*`, `rclone.*`, `repair.healthcheck-concurrency`,
`repair.par2-fetch-concurrency`, `repair.par2-max-memory-mb`, `usenet.cascade.*`,
`usenet.circuit-breaker.initial-cooldown-seconds`, `usenet.segment-cache.enabled`.

Two findings that need action on a 2.x instance:

1. **The 1.x WebDAV password is not adopted** (beta.10): the import stores `upgrade.webdav` as
   `$csharp$$<the plaintext>`, `verify_legacy` parses that as an empty salt plus a v3 blob and
   rejects every attempt, so Basic auth 401s while `webdav.password` stays the generated value —
   every rclone sidecar fails until the password is forced with `INFINIDYSK__WEBDAV__PASSWORD`
   (the report still claims "password accepted from C# at the first sign-in"). The admin login goes
   through the same adoption path, so verify it separately.
2. **`other` is only a _manual_ category in 2.x**: `sab.categories` =
   `radarr,radarr4k,sonarr,sonarr4k,nonplex,books` plus `sab.manual_category: other`. Confirm a
   `cat=other` submission (sync-helper, shelfmark) is still accepted before relying on it.

**After the move to PostgreSQL** (the shape a cutover would use, see Phase A): the store
`infinidysk_v2` holds 15027 items / 13430 NZB blobs in **3.6 GB**, the import took ~13 min, and
`/api/v1/health/summary` reported 7584 healthy / 3 degraded / 156 ignored — the same library as the
SQLite rehearsal. Two consequences that are easy to miss:

- 2.x keeps the **NZB blobs inside its database** (the 7.2 GB `/config/blobs` came over as ~3.6 GB of
  PG data), so `pg_dumpall` grew from 8.9 GiB to ~13 GiB (4.1 GiB of it from this store alone) and
  the dump policy's deep-verification scratch claim went from 12Gi to 20Gi.
- the **admin API key is generated per store**, so the key in the SQLite store is not the key of the
  PostgreSQL store (read `auth` from the config table of the store in use).

**Cleanup after the import** (all verified on the clone, 1.x untouched): `/config` went from 11 GB to
220 KB — `blobs/` (7.2 GB), the stale 2.x SQLite store `infinidysk.sqlite*` (3.5 GB), `db.sqlite*`,
`repair-segments/` (103 MB, the 1.x PAR2 patch store), `metrics.sqlite*`, `warden.db`,
`usenet-migration.db`, `data-protection/` (ASP.NET keys), `session.key`, `rclone/` and `backups/` are
gone; `db-contract.json` and `logs/` stay. `/api/v1/upgrade/leftovers/scan` then reports every item
`missing` (`present: false`), which is what removes the "infinidysk 1.x data" panel from the UI. The
`infinidysk_v1clone` database was dropped; only `infinidysk` (1.x) and `infinidysk_v2` (2.x) remain.
There is no delete endpoint for the leftovers — only `GET`, `scan` and `dismiss` — so the files are
removed by hand and the panel disappears once the scan sees them missing.

Grading access: the admin API key is generated and stored in the settings row `auth.api_key`
(`sqlite3 -readonly /config/infinidysk.sqlite "select value from config where key='auth'"`), the API
is `/api/v1/…` with `X-Api-Key` (plain `/api/…` 401s), and the import report is
`/api/v1/upgrade/report`. `sqlite3 -readonly` on the live file is safe (WAL, one writer).

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

## Provider connection split

Both instances run on the same provider accounts, so **every allowance is divided 80 / 20** in the
1.x backend's favour (it serves the library; v2 only needs enough for a stream plus health checks).
Both manifests carry the split, and `NZBDAV_CONFIG__USENET__PROVIDERS` in the v2 file uses the same
20 % numbers, so even a re-import cannot oversubscribe an account. Every allowance divides evenly by
5, so the split is exact — keep it that way.

| Account                                  | Plan | 1.x (`media/infinidysk`) | 2.x (`media/infinidysk-v2`) |
| ---------------------------------------- | ---- | ------------------------ | --------------------------- |
| primary A (spool group A)                | 50   | 40                       | 10                          |
| primary B (spool group B, first server)  | 75   | 60                       | 15                          |
| primary C (spool group B, second server) | 25   | 20                       | 5                           |
| metered fill (spool group B, bonus)      | 50   | 40                       | 10                          |
| metered block (block account)            | 100  | 80                       | 20                          |

Dropping the test instance means restoring the full allowances (100 %) in
`media/infinidysk/app/externalsecret.yaml` — that is a pod restart of the live backend, so do it in a
quiet window. `NZBDAV_CONFIG__*` is import-only for 2.x, which is why the 20 % share also lives in
`INFINIDYSK__PROVIDERS` (forcing a setting needs a restart, not a UI edit).

## Phase C — results so far

| #   | Test                                     | Result                                                                                                                                                                                                                                                                                             |
| --- | ---------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Consumer mount (`media-debug` → v2:3000) | **pass** — its sidecar mounts v2's WebDAV, the farm's absolute `.ids` symlinks resolve through the mount, a 3.26 GB release streams                                                                                                                                                                |
| 2   | *arr SAB integration                     | **connectivity pass** — Radarr's and Sonarr's `downloadclient/test` against `infinidysk-v2:3000` both return 200 (version/category negotiation included). A real grab is still open, see below                                                                                                     |
| 3   | Health check                             | **pass** — `POST /api/v1/files/{id}/check` → 202, then `degraded` with `1 of 8115 segments missing or corrupt`; `repair: none`, and `degraded_tolerance` keeps serving it. That is the shape of the PAR2 gap: 2.x _locates_ the gap precisely but cannot patch it                                  |
| 6   | Sign-in via authentik (canonical host)   | **pass** (2026-11-20, operator-verified in a browser): the OIDC redirect, the `Platform` binding and the session all work on `https://infinidysk.480p.com`. The 1.x _local_ admin-password adoption is therefore untested but also unused — SSO is the way in                                      |
| 7   | Prometheus export                        | **pass** — `INFINIDYSK__METRICS__PROMETHEUS` + `/metrics`: 401 without credentials, 200 with `X-Api-Key` **or** `Authorization: Bearer`, 586 `infinidysk_*` series (incl. `provider_bytes_total{workload="stream                                                                                   | queue | health"}`, which is what a re-grab-rate measurement needs) |
| 8   | Throughput A/B                           | **2.1x in 2.x's favour** — same file, same node (`w-ovhsbg3`), 400 MB cold ranges via each consumer's rclone sidecar: v2 **90 MB/s** twice (89.8 / 90.1, offsets 1 GB and 2.4 GB) vs v1 **42 MB/s** twice (42.1 / 42.8, offsets 2 GB and 1.4 GB). Offset-independent, so not a read-ahead artefact |

Open, needing a decision or a real download:

- **Real arr grab** (the last unproven link: grab → v2 SAB → `completed-symlinks` → Arr import scan → `removeCompletedDownloads` → v2 history delete). Proposal: a throwaway Radarr root folder (`/aio/symlinks/v2test/movies`) on the real farm, one small monitored movie, v2 as the only enabled client, then remove the movie, the root folder and the client. Isolated from the existing library.
- **RAR class**: 2.x's queue policy is hardcoded (`crates/arr/src/queue.rs`). Covered by it: "found archive file, might need to be extracted" (our rule 4), sample detection, unsupported extension, no audio tracks, unparseable names, "no files found are eligible for import in". **Not covered:** our rules 1–3 (`Compressed RAR archives are intentionally unsupported`, `Failed to parse RAR volume headers`, `No importable media files found`) and rule 5 (`matched to series by ID`, which 1.x removed _without_ searching). Those entries will wait for a human instead of being blocklisted — needs one real RAR-packed grab to confirm what the Arr actually reports.
- **`infinidysk-sync-helper` against v2**: it runs on v2 (SAB history + WebDAV tree visible, 2/2), but its `mode=history` pass has not yet had a real `other`-category job to place — the first manual NZB after the cutover is its real test.

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

## Re-import recipe (the 1.x-shaped block)

2.x reads `NZBDAV_CONFIG__*` **once**, during the import, and ignores it afterwards. That block was
removed from `externalsecret.yaml` / `helmrelease.yaml` once the import finished (the whole config
now uses the durable `INFINIDYSK__*` surface), so a re-import needs it back for the first start:

1. Re-clone `/config` (fresh snapshot, or bump the snapshot names in `app/volumesnapshot.yaml`) and
   re-create the reader database: `create database infinidysk_v1clone owner infinidysk`, then
   `pg_dump … infinidysk | psql … infinidysk_v1clone`.
2. Drop and re-create the empty store (`drop database infinidysk_v2` + `create database …`).
3. Add `DATABASE_PROVIDER: postgres` + `DATABASE_CONNECTION_STRING` (Database=`infinidysk_v1clone`)
   and the 1.x-shaped settings below — the values are the _import_ inputs, not the live ones; the
   `INFINIDYSK__*` overlay still wins for everything it sets.
4. After the import reports `upgrade.state = "done"`, remove the reader variables and the 1.x block
   again (git history: commit `821d1471` has the full manifest as it was).

The two structured values (PascalCase, unknown properties abort the import):

```yaml
NZBDAV_CONFIG__USENET__PROVIDERS: |
    {"Providers":[
      {"Type":1,"Host":"news.eweka.nl","Port":563,"UseSsl":true,"User":"…","Pass":"…","MaxConnections":10,"Nickname":"eweka","StorageGroup":"omicron"},
      {"Type":1,"Host":"eunews.frugalusenet.com","Port":563,"UseSsl":true,"User":"…","Pass":"…","MaxConnections":15,"Nickname":"frugal-eu","StorageGroup":"frugal"},
      {"Type":1,"Host":"news.frugalusenet.com","Port":563,"UseSsl":true,"User":"…","Pass":"…","MaxConnections":5,"Nickname":"frugal-us","StorageGroup":"frugal"},
      {"Type":3,"Host":"bonus.frugalusenet.com","Port":563,"UseSsl":true,"User":"…","Pass":"…","MaxConnections":10,"Nickname":"frugal-bonus"},
      {"Type":3,"Host":"eunews.blocknews.net","Port":563,"UseSsl":true,"User":"…","Pass":"…","MaxConnections":20,"Nickname":"blocknews","StorageGroup":"netnews"}
    ]}
NZBDAV_CONFIG__ARR__INSTANCES: |
    {"SonarrInstances":[{"Name":"Sonarr","Host":"http://sonarr.media.svc.cluster.local:80","ApiKey":"…","Enabled":true}, …],
     "RadarrInstances":[{"Name":"Radarr","Host":"http://radarr.media.svc.cluster.local:80","ApiKey":"…","Enabled":true}, …]}
```

plus the scalar inputs that have no `INFINIDYSK__*` counterpart (they describe 1.x behaviour the
import needs to see): `NZBDAV_CONFIG__API__KEY`, `NZBDAV_CONFIG__WEBDAV__{USER,PASS}`,
`NZBDAV_CONFIG__RCLONE__MOUNT_DIR`, `NZBDAV_CONFIG__MEDIA__LIBRARY_DIR`,
`NZBDAV_CONFIG__API__{CATEGORIES,MANUAL_CATEGORY,IMPORT_STRATEGY,ADDURL_TRUSTED_HOSTS}`,
`NZBDAV_CONFIG__API__{ENSURE_ARTICLE_EXISTENCE_CATEGORIES,ARTICLE_EXISTENCE_CHECK_MODE,ENSURE_IMPORTABLE_VIDEO}`,
`NZBDAV_CONFIG__API__NZB_BACKUP_{ENABLED,RETENTION_DAYS}`,
`NZBDAV_CONFIG__USENET__{SEGMENT_CACHE__ENABLED,CASCADE__ENABLED,CASCADE__RETRY_PRIMARY_ON_MISS,CIRCUIT_BREAKER__INITIAL_COOLDOWN_SECONDS}`,
`NZBDAV_CONFIG__ARR__HEALTH_ENABLED`, `NZBDAV_CONFIG__QUEUE__WORKER_COUNT`,
`NZBDAV_CONFIG__REPAIR__ENABLE`.

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
| 1.x WebDAV/admin password adoption                          | Basic auth 401s on beta.10 until the password is forced                                                          |
