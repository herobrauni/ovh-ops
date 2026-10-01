# Jellyfin v12 upgrade plan

Upgrade `media/jellyfin` from the JPVenson PostgreSQL fork image `10.11.11-1`
to v12. All facts below were verified against the live cluster on 2026-09-30.

## Status log

- **2026-10-01 — execution started** on branch `feat/jellyfin-v12` (worktree-isolated).
- **Phase 0 reordered (user decision)**: the baseline full scan moves to *after* the upgrade. Two reasons: (a) the v12 upgrade requires a full library rescan anyway, so it would be done twice; (b) zurg work is actively in flight (separate agent) and file availability is a moving target. The upgrade-first order also gets us off 10.11.11 before attempting any more scans — see the scan-failure finding below.
- **Finding — full library scans fail on 10.11.11 + PG fork**: a scan triggered 2026-10-01 10:07 UTC died 7.5 min in, and the 2026-09-30 10:25 UTC run failed the same way: post-scan task `BaseItemRepository.UpdateInheritedValues()` throws `ObjectDisposedException (IServiceProvider)` out of the EF `DbContextPool`. This is the actual root cause of the stale-library state (scans never completed since the zurg cutover). The scan DID import: 6,007 items now carry `/aio/remote/zurg/…` paths (playback-relevant catalogue is zurg-based); 6,374 stale `/aio/symlinks/*` rows remain and are expected to be removed by v12's first-boot path-based cleanup + the post-upgrade full scan. If the post-upgrade scan fails with the same signature, root-cause in JPVenson/Jellyfin.Pgsql issues before proceeding.
- **Phase 1 backups DONE**:
  - PG logical dump: `~/Backups/jellyfin/jellyfin-pre-v12.pgdump` (13.4 MB, `-Fc`, verified with `pg_restore --list`)
  - Config tarball (excl. re-fetchable `metadata/`/`log`/`cache`): `~/Backups/jellyfin/jellyfin-config-pre-v12.tgz` (5.5 MB)
  - Pinned kopiur snapshot: `Snapshot/jellyfin-pre-v12` (ns media, `spec.pin: true`, tag `reason: pre-upgrade`) — **Succeeded** 2026-10-01
- **Phase 2 upgrade executed 2026-10-01 (with one incident — see below)**: PR #1328 merged (`7a920216`); Flux kustomization was suspended before merge, resumed/reconciled manually; HelmRelease upgrade to `12.1-2` succeeded; new pod rolled.
- **Incident 1 — `MigrateRatingLevels` (20260910120000) is PostgreSQL-incompatible.** First migration boot: pre-migration PG dump `PgsqlBackups/20261001110849_jellyfin.sql` (74.9 MB) ✅ → `DisableLegacyAuthorization` ✅ → `Jellyfin12.1` EF migration (6s) ✅ → `MigrateLinkedChildren` incl. the path-based cleanup found **5,714 stale items** (the dead `/aio/symlinks/*` rows) and removed them (~17 min) ✅ → then `MigrateRatingLevels` **failed** with `A command is already in progress: SELECT DISTINCT b."OfficialRating"` — the routine iterates a deferred `IQueryable` (open DataReader) and runs `ExecuteUpdate` on the same connection: legal on SQLite, illegal on Npgsql. The fork's guardrail **auto-restored the pre-migration backup** (DB back to exact pre-migration state) and the server retried startup in-process — an unbounded 20-min removal → fail → restore loop.
  - **Containment**: scaled the deployment to 0. The pod stays "ready" with the v12 startup page while retrying, so probes cannot catch this loop.
  - **Not fixed upstream**: JPVenson/Jellyfin.Pgsql#47 — the `release-12.z` copy (`20260915120000_MigrateRatingLevels`) has the **same** `Distinct()` loop, so future 12.1.x bumps will hit it again unless the routine is skipped the same way (the pre-inserted history row keys on the migration ID, which changes per copy — re-check on every image bump).
  - **Workaround**: code migrations are recorded in `__EFMigrationsHistory` (`HistoryRow(BuildCodeMigrationId, version)`), so the row `('20260910120000_MigrateRatingLevels','12.1.0')` was inserted manually — the server skips the broken routine. Skipped work: recalc of `InheritedParentalRatingValue`/`SubValue` from `OfficialRating` — cosmetic, recomputed on item metadata refresh; no other migration depends on it. (There is also an old `20250420220000_MigrateRatingLevels` row from the 10.11 era — the routine has been re-cast repeatedly.)
- **Incident 2 — `StripEmbeddedLinkedChildren` (20260911120000) uses SQLite `json_valid()`** in raw SQL (`UPDATE "BaseItems" SET "Data" = json_remove(...) WHERE ... json_valid("Data") = 1`) — `function json_valid(text) does not exist` on PG (second restore+retry cycle). Workaround: ran the PG-safe equivalent manually and inserted its history row:
  ```sql
  CREATE OR REPLACE FUNCTION pg_temp.try_jsonb(t text) RETURNS jsonb AS $$
  BEGIN RETURN t::jsonb; EXCEPTION WHEN OTHERS THEN RETURN NULL; END $$ LANGUAGE plpgsql;
  UPDATE "BaseItems"
  SET "Data" = (pg_temp.try_jsonb("Data") - 'LinkedChildren' - 'ExtraIds' - 'SupportsExternalTransfer')::text
  WHERE "Data" IS NOT NULL
    AND ("Data" LIKE '%"LinkedChildren"%' OR "Data" LIKE '%"ExtraIds"%' OR "Data" LIKE '%"SupportsExternalTransfer"%')
    AND pg_temp.try_jsonb("Data") IS NOT NULL;
  INSERT INTO "__EFMigrationsHistory" ("MigrationId","ProductVersion")
    VALUES ('20260911120000_StripEmbeddedLinkedChildren','12.1.0');
  ```
  All OTHER pending code migrations were audited (no raw SQLite SQL; the other `.Distinct()` uses materialize via `ToList` first) — these two are the complete broken set for the 10.11.11→12.1 path on this fork. The fork author explicitly does not support older→latest upgrades (JPVenson/Jellyfin.Pgsql#47).
- **Gotcha**: `kubectl exec pod -- psql <<EOF` silently does nothing without `-i` (stdin isn't attached) — the first attempt of the strip fix ran zero statements; re-run with `kubectl exec -i`.
- **Startup-probe budget**: the cleanup pass re-runs on every boot attempt and takes 17–45 min over the zurg mount depending on load; failure→restore cycles lose removal progress but **probe kills keep committed batches** (each pass resumes from fewer stale rows). PR #1333 raised the startup probe to `failureThreshold: 600` (100 min) so one pass fits; final pass completed **`Startup complete 0:11:22`**. Revert to 30 after the post-upgrade scans.
- **Result (14:51 UTC)**: server up on **12.1.0**, `/web/` 200, public `https://jellyfin.480p.com/` 302 → app; zurg-style `Authorization: MediaBrowser Token=…` auth on `/System/Info` returns **200** (push-scan integration intact); migration history complete (`Jellyfin12.1` EF + all code migrations incl. the two skip rows); stale symlink rows 6,374 → **660** (remainder have real files in the farm — invisible to libraries, purged by the full scan); zero `[ERR]` post-startup.
- **encoding.xml fix**: 12.1 rejects the old `<EncoderPreset xsi:nil="true" />` ("EncoderPreset is no longer nullable") and falls back to defaults with an XML parse error on every boot; set to `<EncoderPreset>veryfast</EncoderPreset>` (the default) in `/config/config/encoding.xml` on the PVC.
- **v12 startup behavior worth knowing**: during migration/startup the web UI serves a styled **503** (`server: Kestrel`, `retry-after: 005`) while `/System/Info/Public` already answers 200 — don't mistake it for a gateway outage; probes are TCP so they pass only once the port binds.

## Current state (verified)

| Item | State |
|---|---|
| Image | `ghcr.io/jpvenson/jellyfin.pgsql:10.11.11-1@sha256:67ffa318…` (unofficial PG fork, **not** upstream) |
| Database | CNPG `postgres18`, db `jellyfin`, **154 MB**, 24,378 `BaseItems` |
| Users | **one** (`brauni`) — no case-duplicate usernames ✅ |
| Third-party plugins | **none** — `/config/plugins` holds only the fork's bundled `PostgreSQL` provider + configs of the built-in metadata plugins ✅ |
| Alternate versions | **0** rows with `PrimaryVersionId` ✅ |
| Trickplay | **0** `TrickplayInfos` rows ✅ |
| Live TV | not used ✅ |
| Clients (DB `Devices`) | only `Jellyfin Web 10.11.11` seen recently ✅ |
| Config PVC | `jellyfin` (ceph-block, 25Gi, 8.9G used — 8.8G is re-fetchable `/config/metadata`) |
| Backups | kopiur `SnapshotPolicy/jellyfin` (ns media; keepHourly 12 / daily 14 / weekly 8 / monthly 6 / annual 1) + CNPG barman for the whole `postgres18` cluster |
| Integrations | zurg push-scan (`jellyfin_server_url` + `JELLYFIN_TOKEN`); Homepage link annotation; **no** Gatus endpoint; public route, no auth proxy |
| Probes | TCP socket probes; **startup caps at 5 min** (30×10s) |

## Target version

`ghcr.io/jpvenson/jellyfin.pgsql:12.1-2@sha256:b1cafefc4732895b9bece7da1787690aa462ee2e46e968b99c735754d95c785d`

- Fork image `12.1-2` = upstream `jellyfin/jellyfin:12.1` (published 2026-09-15) + the PG plugin, built 2026-09-29T14:18Z from fork `main@a5957c7`.
- **`-2` specifically, not `-1`**: it includes PR #48 ("Fix the 12.1 migration on PostgreSQL" — uuid casts, orphaned Permissions/Preferences cleanup, drops an SQLite-only rowid fix-up) and PR #49 ("RestoreBackupFast into an emptied schema, all or nothing"). `-1` predates both.
- The fork image ships `pg_dump`/`psql` (postgresql-client-18) and does a **pre-migration DB dump into `/config/data/PgsqlBackups/`** automatically (`MigrationBackupFast`), mirroring upstream's pre-migration SQLite backup.
- Renovate does not track this image (non-semver `12.1-2` tag); no competing PR exists. The bump is fully manual/controlled.

## Breaking/behavior changes in 12.0 → impact on us

| Change (upstream) | Exposure | Verdict |
|---|---|---|
| One-way EF Core DB migration, no rollback without restore | Everything lives in PG (`BaseItems`, `Users`, …) + config XMLs | **Main risk → full backup story below** |
| **Full library rescan REQUIRED** after upgrade; first scan much longer | Our media is zurg WebDAV (Usenet-backed). Listing is zurg-DB-cheap; ffprobe of "changed" items pulls real bytes | Schedule it; expect a long scan window |
| Legacy authorization disabled by default + migration flips existing installs | zurg uses `Authorization: MediaBrowser Token=…` (verified in zurg source + tests) = the **non-legacy** scheme ✅. Only recent client is Jellyfin Web ✅ | Low. Escape hatch: `EnableLegacyAuthorization=true` in `system.xml` (still honored in 12.x, removal planned for the next major) |
| Legacy route prefixes removed (`/emby/*`, `/mediabrowser/*`) | Nothing in-repo uses them (zurg, homepage, probes all use canonical paths) | ✅ none |
| Removed API routes: `EasyPassword`, `CriticReviews`, `NetworkShares`, `MediaEncoder/Path`, `LiveTv/Recordings/Groups/{id}`, **`QuickConnect/Initiate`** | zurg calls only `/Library/VirtualFolders`, `/Items`, `/Library/Media/Updated`, `/System/Info(/Public)` — all still present. `QuickConnect/Initiate` is used only by zurg's **dashboard setup helper**, which we don't use (token already configured) | ✅ none at runtime |
| Global subtitle config removed → per-library | Check Dashboard → Subtitles; re-apply per library if anything was set globally | Trivial, note in post-checks |
| Symlinks resolved only at playback time | Libraries are zurg-only (`__magic__` has no symlinks); the symlink farm is parked | ✅ actually beneficial |
| Auto-resolved alternate versions removed | 0 items affected (verified) | ✅ none |
| Username case-unique normalized index (migration crashes on case-duplicates) | Single user | ✅ none |
| Sorting by `SortName`/`CleanName`; no image upscaling | Cosmetic re-ordering / smaller thumbs possible | Cosmetic |
| Plugins must be retargeted to .NET 10 | Only plugin is the fork's own PG provider, already rebuilt in the 12.1-2 image | ✅ none |
| FFmpeg 8.1 transcode | CPU-only transcode (no `/dev/dri` mounted) | Spot-check one transcode post-upgrade |
| New `--mode=MigrateSystem` startup flag | Fork entrypoint passes `"$@"` through, so it *could* run migrations without serving — unverified with the fork | Skip; let the pod migrate with backups in place |
| Migrations + full path-based cleanup on first boot can take a while | **Our startup probe kills the pod after 5 min** → mid-migration restart risk | **Bump startup probe before upgrading** |

## ⚠ Pre-existing issue to fix FIRST (not caused by v12)

All **978 Movies and 4,736 Episodes in the DB still point at `/aio/symlinks/*`**.
The five libraries were re-pointed to `/aio/remote/zurg/__magic__/…` on 2026-09-30
(verified via `/Library/VirtualFolders`), but the last library scan
(2026-09-30 10:25 UTC) ran **before** the cutover, and zero items carry zurg paths.
With the altmount sidecar parked, those symlink targets no longer exist in the pod,
so playback of the current catalogue is presumably broken/stale.

Do **not** debug this on top of a major migration: fix it on 10.11.11 first so the
upgrade starts from a known-good, verified baseline.

## Runbook

### Phase 0 — baseline fix (MOVED post-upgrade)

Originally planned as a pre-upgrade full scan; **moved after the upgrade** (see status log — v12 requires a full rescan anyway, scans were failing on 10.11.11, and zurg availability was in flux). What a partial scan already achieved on 10.11.11 is in the status log. The remaining cleanup (purging the 6,374 stale `/aio/symlinks/*` rows) happens via v12's first-boot path-based cleanup + the Phase 3 full scan.

### Phase 1 — backups — DONE 2026-10-01

1. Fresh **pinned** kopiur snapshot of the config PVC (survives GFS pruning):
   ```sh
   kopiur snapshot now jellyfin -n media --pin   # or apply a Snapshot CR with spec.pin: true
   kubectl get snapshots -n media   # wait for Succeeded
   ```
2. Manual logical DB dump to the workstation (the authoritative rollback artifact):
   ```sh
   kubectl exec -n dbms postgres18-1 -c postgres -- pg_dump -Fc -d jellyfin > jellyfin-pre-v12.pgdump
   ls -la jellyfin-pre-v12.pgdump   # expect tens of MB
   ```
3. Cheap config backup of everything except re-fetchable metadata (~10 MB):
   ```sh
   kubectl exec -n media deploy/jellyfin -c app -- tar cz --exclude=./metadata -C /config . > jellyfin-config-pre-v12.tgz
   ```
4. Record the current image pin (for rollback): `10.11.11-1@sha256:67ffa31823880bd76b9dbe3cde57ed3d31e06f6a955d544247cd370c67d58306` (already in Git).

### Phase 2 — upgrade

1. `flux suspend kustomization jellyfin -n media` (defense in depth against mid-op reconciles).
2. Branch `feat/jellyfin-v12`, edit `kubernetes/apps/media/jellyfin/app/helmrelease.yaml`:
   - image tag → `12.1-2@sha256:b1cafefc4732895b9bece7da1787690aa462ee2e46e968b99c735754d95c785d`
   - **temporarily** raise the app container startup probe: `failureThreshold: 30` → `180` (30 min headroom for migrations + path cleanup)
   - PR, let flate CI run, merge.
3. `flux resume kustomization jellyfin -n media && flux reconcile kustomization jellyfin -n media`.
4. Watch the rollout:
   ```sh
   kubectl logs -n media deploy/jellyfin -c app -f
   ```
   Expect: entrypoint refreshes the PostgreSQL plugin → **pg_dump into `/config/data/PgsqlBackups/` (verify the file appears and its size)** → EF migrations (`Jellyfin12.1` migration: uuid casts, LinkedChildren, …) → path-based cleanup → HTTP up.
5. Once serving: `GET /System/Info` shows `12.1`; log in via web; confirm the single user works.

### Phase 3 — required post-upgrade work

1. **Full library scan** (upstream-required; restores alt-version structures, fixes type issues): Dashboard → Libraries → Scan All Libraries.
   - Expect a long first scan over the zurg mount; watch jellyfin logs and zurg CPU (the `nzb-index` mmap warms page cache — looks like throttling, isn't).
   - "Newly added" badges on some movies are expected (upstream type fixes).
2. Verify zurg push-scan still works end-to-end: trigger a small `__magic__` placement (or `POST /Library/Media/Updated` with the zurg token) and watch the jellyfin log for the refresh; confirm a `zurg_scan`-side success log.
3. Re-check per-library subtitle settings (global config was removed), sorting order, and Dashboard → Plugins (should still be empty).
4. Sanity-check migration history (top row should be the `Jellyfin12.1` migration) and confirm no stale symlink rows remain (query from Phase 0):
   ```sh
   kubectl exec -n dbms postgres18-1 -c postgres -- psql -d jellyfin -c 'SELECT * FROM "__EFMigrationsHistory" ORDER BY "MigrationId" DESC LIMIT 3'
   ```
5. Playback spot-checks: direct play + one transcode (FFmpeg 8.1) + subtitles.
6. Revert the startup probe to `failureThreshold: 30` in a follow-up commit once stable (or deliberately keep a modest bump, e.g. 60).

## Rollback

DB and config roll back **together**; the image pin reverts in Git.

1. `flux suspend kustomization jellyfin -n media`; scale to 0 (`kubectl scale deploy/jellyfin -n media --replicas=0`).
2. Restore the database:
   ```sh
   kubectl exec -n dbms postgres18-1 -c postgres -- psql -c \
     "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='jellyfin' AND pid <> pg_backend_pid()"
   kubectl exec -n dbms postgres18-1 -c postgres -- dropdb jellyfin
   kubectl exec -n dbms postgres18-1 -c postgres -- createdb -O jellyfin jellyfin
   cat jellyfin-pre-v12.pgdump | kubectl exec -i -n dbms postgres18-1 -c postgres -- pg_restore -d jellyfin --no-owner
   ```
   (Alternative: the fork's own dump in `/config/data/PgsqlBackups/*_jellyfin.sql` — plain `pg_dump --clean`, restorable with `psql -f`.)
3. Restore the config PVC from the pinned kopiur snapshot: recreate the `jellyfin` claim via the kopiur `Restore` populator path (component pattern) targeting the pinned snapshot, **or** if only XML drift matters, overlay the Phase-1 tarball onto the existing PVC.
4. Revert the image pin to `10.11.11-1@sha256:67ffa318…` in Git, resume Flux, reconcile.
5. Full library scan; spot-check playback.

## Risks / notes

- **Biggest risk is a fork-specific migration bug** (upstream's 12.1 PG migration already needed a follow-up fix). Mitigations: we take `-2` (has both fixes), we have an independent `pg_dump -Fc`, the fork does its own pre-migration dump, and the config PVC has a pinned snapshot.
- The fork is explicitly experimental ("use at your own risk") and **still required**: upstream 12.x has the pluggable database layer (`IJellyfinDatabaseProvider`, `database.xml` `PLUGIN_PROVIDER` — merged from JPVenson's #13451, which is why the fork is now just a plugin DLL on top of the official image), but ships **only the SQLite provider** (`src/Jellyfin.Database/Jellyfin.Database.Providers.Sqlite` is the sole provider in the tree; no Npgsql anywhere). PG itself was deliberately excluded from that merge, jellyfin#15383 was closed same-day, and org discussion #17211 (still active as of 2026-09) shows collaborators consider large-scale PG out of scope. There is also no supported PG→SQLite path back, so the fork is a long-term commitment until upstream ships its own provider — track https://github.com/JPVenson/Jellyfin.Pgsql/issues and #17211.
- 12.0 also ships real security fixes (subtitle path FFmpeg argument injection, path traversal hardening) — worth having promptly given jellyfin is publicly exposed (no gateway auth).
- Don't let the pod restart mid-migration: that's why the startup probe bump is in the same PR, and why we suspend Flux first.
- First boot + first scan is the long pole; everything else is minutes (154 MB DB).
