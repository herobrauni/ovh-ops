# Adding InfiniDysk to `media` (zurg replacement)

Working plan for deploying InfiniDysk (`media/infinidysk`) and replacing zurg as the
Usenet streaming backend. End state: InfiniDysk serves the library through its
WebDAV VFS, the \*arrs grab through its SABnzbd-compatible endpoint and import
**symlinks** into the `symlinks` PVC (the old altmount-era farm shape, now backed by
InfiniDysk's `.ids` tree), Plex and Jellyfin read that farm through rclone sidecars,
and zurg + `zurg-sync-helper` + `zurg-debug` are decommissioned.

InfiniDysk is the successor of `nzbdav-dev/nzbdav` ("The NzbDAV SuperFork",
`ghcr.io/infinidysk/infinidysk`). The dormant `media/nzbdav` app is the old upstream
of the same lineage: **ignore it** (do not enable it), but its manifests are a
reference for how this repo previously wired the symlink-farm flow.

**This plan supersedes Phases 4–5 of [`zurg-migration.md`](./zurg-migration.md)**
(Plex zurg cutover + teardown): do not finish that doc's teardown phases against a
live zurg if this migration proceeds — fold them into Phase 6 here. Nothing on this
page is applied yet by writing it down; every phase lists its own verification and
rollback.

Primary references (read these before executing):

- https://www.infinidysk.com/getting-started/docker/ — image, entrypoint, health
- https://www.infinidysk.com/configuration/headless/ — `NZBDAV_CONFIG__...` overlay
  (the GitOps config surface; JSON shapes are PascalCase and **not forward
  compatible** — unknown property names abort startup)
- https://www.infinidysk.com/configuration/sabnzbd/ — \*arr-facing API settings
- https://www.infinidysk.com/getting-started/connect-arr/ — download-client values,
  **Remove Completed**, rejected-compressed-archive behavior
- https://www.infinidysk.com/guides/mounting-webdav/ — rclone sidecar flags (`--links`!)
- https://www.infinidysk.com/guides/import-strategies/ — symlinks vs STRM, path
  consistency rule
- https://www.infinidysk.com/guides/media-servers/ — Plex/Jellyfin expectations
- https://www.infinidysk.com/getting-started/setup-guide/ — Library Directory rules
- https://www.infinidysk.com/configuration/usenet/ — provider types / storage groups
- Repo references: `kubernetes/apps/media/zurg/` (routes/CNP/kopiur shape),
  `kubernetes/apps/media/sonarr/app/helmrelease.yaml` (rclone sidecar pattern),
  `kubernetes/apps/media/zurg-debug/app/helmrelease.yaml` (canonical consumer sidecar),
  `docs/authentik-forward-auth.md` (SSO runbook), `docs/zurg-migration.md`
  (current zurg state + the altmount symlink-farm mechanics being restored).

---

## Progress log

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked.

| Phase                                              | Status | Note                                                                                           |
| -------------------------------------------------- | ------ | ---------------------------------------------------------------------------------------------- |
| 0 — pre-flight (Infisical keys, decisions)         | `[x]`  | `/infinidysk/*` created 2026-10-19 (9 keys); `/servarr/API_KEY` reused for the \*arr instances |
| 1 — deploy `media/infinidysk` standalone           | `[x]`  | manifests landed in this PR; first rollout happens when it merges                              |
| 2 — consumer scaffold (`infinidysk-debug`, \*arrs) | `[x]`  | `rclone-infinidysk` now runs beside `rclone-zurg` in all 9 consumers (2026-10-20)              |
| 3 — \*arr cutover (client + roots + corpus)        | `[~]`  | corpus imported 2026-10-20 (4,433/4,615); client + roots still to do                           |
| 4 — Plex / Jellyfin cutover                        | `[ ]`  | section locations → farm; no dual scanning                                                     |
| 5 — Bazarr + manual-NZB (`other`) pipeline         | `[ ]`  |                                                                                                |
| 6 — teardown zurg (+ fold altmount teardown)       | `[ ]`  | only after 1–2 quiet weeks                                                                     |
| 7 — docs + `AGENTS.md` findings                    | `[~]`  | wiring recorded in `AGENTS.md`; behavior findings still to come from Phase 3                   |

### Log

- **2026-10-19** — **Phase 0 done.** Created `/infinidysk/{API_KEY,WEBDAV_USER,
  WEBDAV_PASSWORD,EWEKA_USERNAME,EWEKA_PASSWORD,FRUGAL_USERNAME,FRUGAL_PASSWORD,
  BLOCKNEWS_USERNAME,BLOCKNEWS_PASSWORD}` in Infisical (project `ovh-ops-u1ua`,
  env `prod`). NNTP values were copied from `/zurg/*` so `/infinidysk/*` is
  self-contained for teardown. The rendered ExternalSecret was validated against
  the live store with a throwaway copy in `default` (then deleted): JSON blobs
  parse, provider types/storage groups are correct, `FRONTEND_BACKEND_API_KEY`
  equals `NZBDAV_CONFIG__API__KEY`, and all four \*arr hosts resolve.
- **2026-10-19** — **Phase 1 done (Git manifests).** Added `media/infinidysk`
  (ks.yaml, HelmRelease, ExternalSecret, HTTPRoute, CiliumNetworkPolicy), the
  lifecycle allowlist entries, and the Authentik provider/application/binding
  plus the outpost hostname. Image pinned to `v1.6.2` (multi-arch index digest
  `sha256:f7799f2bfb629c397142a19e103bcdb119b317a6e3762b5606b82a71d642978d`).
  `flate test all` passes (219 resources) and
  `util/check_security_invariants.sh` passes.
- **2026-10-19** — **Phase 2 partially done.** `media/infinidysk-debug` shipped
  as the canonical consumer-sidecar playground. The four \*arrs were
  deliberately **not** touched: a bad WebDAV mount or a missing CNP entry blocks
  pod readiness, so shipping sidecars before the backend has ever run could take
  the media stack down on merge. Add them in their own PR once InfiniDysk is
  verified healthy.

- **2026-10-19** — **Phase 1 verified live** (PRs #1493/#1494/#1495/#1496). Pod
  `2/2 Running`; WebDAV tree at `/aio/remote/infinidysk` lists `README`,
  `completed-symlinks`, `content`, `nzbs` (plus `.ids`) from both the debug pod
  and the app's own self-mount, and is writable from a consumer.
  `https://infinidysk.480p.com/healthz` → `200` (Gatus), `/` → `302` to SSO,
  and `/outpost.goauthentik.io/auth/envoy` → `302`. Authentik holds 23 providers
  including InfiniDysk; **the embedded outpost answered `404` until
  `deploy/authentik-server` was restarted**, exactly as `AGENTS.md` predicts for
  a provider added in the same commit as its `SecurityPolicy`.
- **2026-10-19** — **PostgreSQL cutover verified.** `/config/db-contract.json`
  reports `provider: postgres` with `metrics`/`usenetMigration` still `sqlite`,
  the `infinidysk` database on `postgres18` has 25 tables and a populated
  `__EFMigrationsHistory` (tip `20260921210000_Add-Health-Alert-History-Lookup-Index`),
  and the `postgres-init` initContainer created the role/database. The stale
  SQLite main DB was removed before the switch (fresh install, no admin account).
- **2026-10-19** — **Two deployment traps found and fixed** (both documented in
  the manifests and `AGENTS.md`): (1) composing `DATABASE_CONNECTION_STRING` from
  `$(VAR)` env expansion silently fails because app-template renders `env` in
  sorted key order, so Npgsql received the literal `$(PGPORT)`
  (`Couldn't set port`) — the string is now derived inside the Secret, and the
  app carries its own DB secrets instead of `components/cnpg`; (2) the \*arr
  health poll must target Service port **80**, not the Radarr container port
  7878, or every poll times out. Expect a harmless
  `Cannot load library libgssapi_krb5.so.2` line in the app log: Npgsql probing
  for GSSAPI, irrelevant with password auth.

- **2026-10-20** — **Corpus imported.** `util/nzb-import-job.yaml` streamed
  zurg's NZBs straight off its (read-only) PVC into InfiniDysk's SAB `addfile`,
  categorised by Plex tree. Job ran 22:38 → 05:26 (6.3 h) and **completed**:
  `added=4109 failed=1` uploads, and history now holds all **4,615** planned
  releases — **4,433 Completed**, **182 Failed**. The 1,759 never-placed
  releases were skipped by decision. Per category (completed/total):
  sonarr 2,444/2,603 · sonarr4k 1,074/1,082 · radarr 469/483 ·
  radarr4k 412/414 · other 34/34. Throughput with the article pre-check
  disabled was ~11/min; with it on it had been ~1.5/min (~50 h).

    Failure breakdown (all in InfiniDysk's history, nothing to retry blindly):

    | reason                                            | count | meaning                             |
    | ------------------------------------------------- | ----- | ----------------------------------- |
    | compressed RAR/7z archives unsupported            | 84    | the documented streaming limitation |
    | "Rar signature not found" / bad volume headers    | 50    | damaged or obfuscated RAR sets      |
    | no importable media files                         | 20    | extras/sample-only releases         |
    | inconsistent RAR volume size                      | 6     | truncated uploads                   |
    | missing articles                                  | 5     | expired on the provider             |
    | unreadable media bytes / CRC32 / duplicate volume | 6     | corrupt payloads                    |

    So **141 of 182 (77%) are the compressed-RAR limitation** predicted in
    "Known behavioral differences" — those releases must be re-grabbed as
    stored/direct-media releases, which the \*arrs do automatically once they
    point at this backend. Nothing was deleted from zurg; its corpus is intact.

    The article pre-check was re-enabled afterwards and the import helper's
    CiliumNetworkPolicy entry removed (Job + ConfigMap deleted).

- **2026-10-19/20** — **Connection split re-weighted to 20/80 toward
  InfiniDysk** (#1508): zurg 10/15/5/10/20, InfiniDysk 40/60/20/40/80. Totals
  per account are unchanged (50/75/25/50/100).

- **2026-10-20** — **Phase 2 done.** `rclone-infinidysk` added _beside_
  `rclone-zurg` in every app that mounts zurg: the four \*arrs, both Bazzars,
  Plex, Jellyfin and `media-debug` (writable everywhere except Plex/Jellyfin,
  which get `--read-only`, matching their zurg sidecars). Same proof set as the
  debug pod: `--links`, `--allow-non-empty`, `--poll-interval=0`,
  `--dir-cache-time=20s`, 512M read-ahead, backend URL on **:8080**, each mount
  at exactly `/aio/remote/infinidysk` so symlink targets resolve.
  Cache is bounded at **8G** (not 20G) while both backends coexist — two full
  caches per pod would exceed a worker's ~94Gi ephemeral. Raise to 20G when the
  zurg sidecars are removed.
  Nothing is cut over yet: no download client, root folder or Plex library
  points here; the mounts are inert until Phase 3/4.

### Implementation notes (deviations from the plan text below)

Deliberate deviations; keep them in mind when executing Phases 2–6.

- **One ExternalSecret, not two.** `infinidysk-secret` carries everything (NNTP
  creds, WebDAV creds, API key, rendered JSON); consumer sidecars read only the
  two WebDAV keys with `secretKeyRef`, so they never receive NNTP credentials.
- **`webdav.enforce-readonly` is deliberately NOT set.** The \*arrs clean up
  their completed entries and delete the import source after a symlink move, so
  a read-only WebDAV tree would leave clutter in `completed-symlinks`. The
  backend port (`8080`) is never published through the Gateway.
- **The self-mount is a loopback mount.** InfiniDysk resolves library symlinks
  (targets under `<MOUNT_DIR>/.ids`) for its health/repair checks, so it needs a
  view of the WebDAV tree at `/aio/remote/infinidysk`. The sidecar mounts
  `http://127.0.0.1:8080/` (same pod network namespace), which keeps that
  traffic out of Cilium ingress policy entirely. Consumers use the Service.
- **rclone passwords are obscured at container start**, not stored obscured:
  rclone's obfuscation is not deterministic, so a stored copy would go stale on
  every rotation. Sidecars take the raw value and run `rclone obscure` in their
  entrypoint.
- **No built-in DB backup schedule**: kopiur already snapshots `/config`. The NZB
  backups (`api.nzb-backup-enabled`, retention `0`) stay on, because those files
  are what a mount is rebuilt from. With PostgreSQL as the main DB this mattered
  less anyway (the in-app backup only covers the auxiliary SQLite stores), and the
  PG database itself still needs a `pg_dump` job — tracked for Phase 6.
- **No public SABnzbd bypass route.** The \*arrs use the in-cluster Service on
  `:3000`, which Authentik never sees.
- **rclone sidecar flags follow the Setup Guide except for RC.** Adopted from the
  wizard: `--links`, `--allow-other`, `--vfs-cache-mode=full`, `--buffer-size=0M`,
  `--vfs-read-ahead=512M`, plus `--allow-non-empty` (a stale `/tmp/rclone-*`
  mountpoint otherwise makes the next mount fail — the same class of failure as
  the bazarr FUSE incident) and `--poll-interval=0` (WebDAV has no change feed).
  **RC notifications are deliberately not used**: the wizard pairs `--rc` with
  `--dir-cache-time=1w` because RC pushes invalidations, but a consumer's RC
  endpoint lives in _another pod_ and a sidecar port has no Service/DNS here, so
  InfiniDysk cannot reach it. Without RC the dir cache must stay short
  (`--dir-cache-time=20s`, `--vfs-cache-poll-interval=30s`) or newly imported
  releases stay invisible to the \*arrs. Cache bounds are 20G/24h rather than the
  wizard's 50G/1w because the cache is an `emptyDir` on node ephemeral storage —
  the wizard itself says to size it to available storage. Turn the wizard's
  "Enable rclone RC notifications" toggle **off**. (The in-pod self-mount _could_
  use RC on `127.0.0.1:5572`, but its only consumer is InfiniDysk's own health
  checks, where 20 s of staleness is irrelevant.)
- **Repair cadence stays UI-owned** until measured. zurg's hourly repair pass
  saturated the NNTP pool and had to be slowed to 4h; do not raise InfiniDysk's
  health-check concurrency without re-reading that incident.

---

## Concept mapping (zurg → InfiniDysk)

| zurg (today)                                       | InfiniDysk (target)                                                                                                                       |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `config.yml`, initContainer-seeded from Git        | `NZBDAV_CONFIG__...` env overlay in the HelmRelease (Settings UI = read-only for managed keys)                                            |
| port 9999 (WebDAV + SAB + API + MCP)               | frontend `3000` (UI, SAB API, `/api`, `/ws`) + backend `8080` (WebDAV — rclone connects **directly** here)                                |
| `/config` 30Gi (`nzbs/`, `data/`), kopiur          | `/config` (SQLite, blobs, NZB backups), kopiur 30Gi                                                                                       |
| `__magic__` row-write namespace (imports = rename) | symlink farm on the `symlinks` PVC; imports = symlink recreation from `completed-symlinks` into the library; content addressed via `.ids` |
| SAB `complete_dir` = `__magic__/__all__`           | `completed-symlinks/` on the WebDAV tree; `rclone.mount-dir` must equal the consumers' mount path                                         |
| `magic.allow_delete` tombstones                    | **Remove Completed** on the \*arr client + `Remove Orphaned Files` maintenance                                                            |
| `repair_every_mins`, `par2_patch_cache_mb`         | Settings → Repairs (PAR2 + health checks, Library-Directory-aware)                                                                        |
| media-server push scans (plex/jellyfin tokens)     | **no push integration** — periodic library scans in Plex/Jellyfin                                                                         |
| MCP (unauthenticated tool endpoint)                | none (REST API; leave `ENABLE_API_DOCS` off)                                                                                              |
| `zurg-sync-helper` (manual NZB placement)          | optional `infinidysk-sync-helper`, or manual import                                                                                       |
| `data/local` gauge = copy-detector                 | verify imports are symlinks (`ls -la`), library PVC usage stays flat                                                                      |

## Decisions (pre-resolved; revisit only with cause)

1. **Import strategy: `symlinks`** (not STRM). One global strategy serves both Plex
   and Jellyfin; Jellyfin reads the farm like Plex (media-servers page: symlinks give
   scan-time media info, STRM leaves `0m 0s` until first play). STRM would also need a
   publicly reachable Base URL with embedded WebDAV credentials.
2. **Library layout: restore the altmount-era farm shape** on the existing `symlinks`
   PVC (CephFS RWX, kopiur-backed): \*arr roots `/aio/symlinks/plex_hd/shows`,
   `/aio/symlinks/plex_hd/movies`, `/aio/symlinks/plex_4k/shows`,
   `/aio/symlinks/plex_4k/movies`, plus `/aio/symlinks/other` for non-\*arr content.
   Library Directory setting = `/aio/symlinks` (mounted into the InfiniDysk pod too —
   it must not be the rclone mount or `completed-symlinks`).
3. **Mount path: `/aio/remote/infinidysk` in every consumer pod.** This is the
   `rclone.mount-dir` value; InfiniDysk reports completed paths under it and the
   generated symlinks' targets embed it, so it must be identical in all pods
   (\*arrs, Plex, Jellyfin, Bazarr, debug) — no remote path mappings anywhere.
4. **SAB endpoint is in-cluster only** (`http://infinidysk.media.svc.cluster.local:3000`).
   No public SAB bypass route (unlike zurg's `/api` route) — manual NZB upload goes
   through the SSO-protected UI. Add a bypass route later only if external tooling
   needs it.
5. **SSO: Authentik forward-auth** via `components/authentik` (repo convention; zurg
   has the same). InfiniDysk additionally has its own admin login (first-run
   bootstrap, cannot be env-driven) → double login at the dashboard is accepted.
6. **Database: PostgreSQL (`postgres18`, shared CNPG cluster).** The main operational
   store uses `DATABASE_PROVIDER=postgres` + one ADO.NET `DATABASE_CONNECTION_STRING`
   (role/database `infinidysk`, created by a `postgres-init` initContainer). The two DB
   secrets are defined **locally** in this app's `externalsecret.yaml` instead of via
   `components/cnpg`: the component publishes discrete host/port/db/user keys, and
   composing them in the pod is unreliable because app-template renders `env` in sorted
   key order — `DATABASE_CONNECTION_STRING` resolves before `PGPORT`, so the `$(VAR)`
   placeholders reach Npgsql literally (`Couldn't set port`). Deriving the string inside
   the Secret is the only dependable shape. Postgres support is **new-install only** —
   there is no SQLite→PostgreSQL migration, so an existing `/config/db.sqlite` must be
   removed (delete it while the app is stopped) rather than converted. Consequences:
   `/config` still holds blobs, the NZB corpus and the auxiliary SQLite stores
   (`metrics.sqlite`, `warden.db`, `usenet-migration.db`), so its kopiur snapshot stays
   necessary, but the main DB now needs **PostgreSQL-native backups** (`pg_dump`) — the
   in-app backup page only covers `warden.db`.
7. **`/config` is the NZB corpus holder** — enable `api.nzb-backup-enabled` with
   retention `0` (forever), mirroring zurg's "raw NZBs are the only copy of the
   library" doctrine. kopiur backs it up.
8. **Corpus migration: bulk NZB re-import (Option B), re-grab as fallback (Option A).**
   See Phase 3. This preserves ~5,491 releases without indexer spend; the \*arrs'
   `Downloaded*Scan` re-imports them against existing DB items.
9. **Category names stay as-is**: `other,radarr,radarr4k,sonarr,sonarr4k,nonplex`
   (letters/numbers/dashes are valid; \*arr client configs carry over unchanged).
10. **App name `infinidysk`**, hostname `infinidysk.480p.com`, image
    `ghcr.io/infinidysk/infinidysk` pinned `vX.Y.Z@sha256:...` (pin an exact release
    tag, never `latest`/`lts`/`rc`/`dev`). The `nzbdav/nzbdav` Docker Hub mirror is
    for IPv6-only hosts — not needed here. Deployed as `v1.6.2`.
11. **No public SABnzbd/WebDAV route.** The \*arrs reach `:3000` (frontend/SAB)
    and `:8080` (WebDAV backend) over the in-cluster Service; only the
    authenticated UI is published. zurg needed its bypass route because the \*arrs
    spoke to it over HTTPS, which is not the case here.
12. **`manual-category` is `other`**, so Queue-page uploads land in the tree the
    manual-NZB pipeline already expects.

## Usenet connection split (temporary, while zurg and InfiniDysk coexist)

Both backends authenticate with the **same provider accounts**, so every account's
connection allowance has to be divided between them — two apps each dialing the full
allowance would exceed the plan and get connections refused (and would starve
playback). The split was first applied 2026-10-19 with zurg holding the larger share,
then re-weighted the same day to **20/80 in InfiniDysk's favour** once InfiniDysk
proved it could serve reads: the incoming backend gets most of every allowance and
zurg keeps a working margin until the cutover.

### Original ("OG") zurg settings — restore these when zurg is retired

| Account      | Host                          | Role                                   | OG connections |
| ------------ | ----------------------------- | -------------------------------------- | -------------- |
| Eweka        | ``           | primary (omicron spool)                | **50**         |
| Frugal EU    | `` | primary, priority 1 (frugal spool)     | **75**         |
| Frugal US    | ``   | primary, priority 2 (frugal spool)     | **25**         |
| Frugal bonus | ``  | backup / metered fill                  | **50**         |
| Blocknews    | ``    | backup / metered block (netnews spool) | **100**        |

Aggregate **primaries = 150** (50 + 75 + 25); backups are fill-only and do not count
toward streaming throughput. `warm_connections: 4`. Source of truth:
`kubernetes/apps/media/zurg/app/externalsecret.yaml` (rename it back to the values
above).

### Current split — 20 / 80 (zurg / InfiniDysk)

Applied 2026-10-19 after the initial 70/30-style split: InfiniDysk is the incoming
backend and Plex playback is moving onto it, so it now holds 80% of every allowance
and zurg keeps 20% — enough to serve the existing library until the cutover, not
enough to compete with it for plan connections.

| Account                   | Allowance | zurg (20%) | InfiniDysk (80%) | Total |
| ------------------------- | --------- | ---------- | ---------------- | ----- |
| Eweka primary             | 50        | 10         | 40               | 50    |
| Frugal EU primary         | 75        | 15         | 60               | 75    |
| Frugal US primary         | 25        | 5          | 20               | 25    |
| Frugal bonus (backup)     | 50        | 10         | 40               | 50    |
| Blocknews (backup, block) | 100       | 20         | 80               | 100   |

Primaries: zurg **30**, InfiniDysk **120**. Every allowance divides evenly by 5, so
the percentages are exact integer connection counts — no rounding, no account over
its plan total.

Mapping for InfiniDysk (`NZBDAV_CONFIG__USENET__PROVIDERS`): Eweka/Frugal EU/Frugal US
are `Type: 1` (Pool Connections), Frugal bonus and Blocknews are `Type: 3`
(BackupOnly); `StorageGroup` carries zurg's `backbone` (`omicron`, `frugal`,
`netnews`). See `kubernetes/apps/media/infinidysk/app/externalsecret.yaml`.

**When this split ends:** after Phase 6 (zurg removed) put every InfiniDysk provider
back to its OG number — the allowances are per account, so the whole 150/50/100
becomes available to InfiniDysk alone. Both manifests carry a comment pointing here,
so no one has to guess what the numbers were.

## Known behavioral differences / risks

- **Compressed RAR/7z payloads are rejected.** InfiniDysk streams only direct media
  or _stored/uncompressed_ archive members (RAR `m0`, 7z Copy); compressed archives
  fail the SAB job (`status: Failed`) and the \*arr blocklists/re-grabs. zurg streams
  compressed archives (its `stream_compressed_archives`), so some of the corpus —
  especially older RAR-packed releases — will not mount. Expect this in Phase 3 and
  measure it; those items fall back to Option A (re-grab a stored release).
- **No Plex/Jellyfin push scans.** zurg's targeted-scan integration is gone. Enable
  periodic library scans in both servers and accept scan latency; watch Overview
  **Active Reads** for scan-induced thrash and keep analysis settings light.
- **`Remove Completed` must be ON** for each \*arr download client (Completed
  Download Handling): the \*arr clears the SAB history entry after import; the
  mounted content and library links keep working. Without it, superseded grabs pile
  up until history retention prunes them and their mounts become orphan-cleanup
  eligible.
- **Startup runs DB migrations** before the backend serves; give the startup probe a
  long budget (the Compose healthcheck uses frontend `/healthz`, which answers
  during maintenance).
- **Structured `NZBDAV_CONFIG__...` JSON is not forward compatible.** A property
  name unknown to the running image aborts startup. This mainly bites when _rolling
  back_ to an older image after an upgrade adopted new properties — check the
  release notes of any Renovate bump that changes `usenet.providers` /
  `arr.instances` shape.
- **First-run admin account is not env-configurable** (`RESET_ADMIN_PASSWORD=true`
  is the recovery path). Create the account through the UI once, immediately after
  Phase 1 rollout.
- **WebDAV auth**: rclone env `RCLONE_CONFIG_*_PASS` needs the **obscured** password
  (`rclone obscure`); the sidecar command must obscure the raw secret at start.

---

## Phase 0 — pre-flight (no cluster changes)

1. `git pull --ff-only`; confirm HEAD matches the applied `cluster-apps` revision.
2. Create Infisical folder `/infinidysk/` (project `ovh-ops-u1ua`, env `prod`) —
   verify each key exists **before** any ExternalSecret references it (a missing
   `remoteRef` fails the whole ExternalSecret; the `idlers` lesson). Prove with a
   throwaway ExternalSecret templating `{{ .KEY | len }}`:

    | key                                                                | value source                                                            |
    | ------------------------------------------------------------------ | ----------------------------------------------------------------------- |
    | `/infinidysk/API_KEY`                                              | new random (SAB download-client key **and** `FRONTEND_BACKEND_API_KEY`) |
    | `/infinidysk/WEBDAV_PASSWORD`                                      | new random (avoid `"`, `\`, `$` — JSON/env escaping)                    |
    | `/infinidysk/EWEKA_USERNAME`, `/infinidysk/EWEKA_PASSWORD`         | copy of `/zurg/*`                                                       |
    | `/infinidysk/FRUGAL_USERNAME`, `/infinidysk/FRUGAL_PASSWORD`       | copy of `/zurg/*`                                                       |
    | `/infinidysk/BLOCKNEWS_USERNAME`, `/infinidysk/BLOCKNEWS_PASSWORD` | copy of `/zurg/*`                                                       |

    Copying (not referencing) the NNTP creds keeps `/infinidysk/*` self-contained so
    `/zurg/*` can be deleted at teardown. The \*arr API key is **not** duplicated:
    the ExternalSecret templates it from `/servarr/API_KEY` (ESO cannot read
    `servarr-secret` itself).

3. Read the phase-local references listed at the top. Confirm current upstream image
   tag + digest (`crane digest`/`skopeo` or the GitHub release) at implementation
   time.
4. Decide the corpus question per "Decisions" #8; do not change it mid-phase.

**Verification**: key list above readable via the `infisical` ClusterSecretStore.
**Rollback**: n/a (Infisical-only).

---

## Phase 1 — deploy `media/infinidysk` standalone

New tree `kubernetes/apps/media/infinidysk/` mirroring `media/zurg/`:

- `ks.yaml` — Flux Kustomization `infinidysk`, `targetNamespace: media`,
  components `dnsendpoint`, `authentik`, `kopiur`; `dependsOn: infisical,
  kopiur-repository, rook-ceph-cluster, authentik`; `postBuild.substitute`:
  `APP: infinidysk`, `DOMAIN: 480p.com`, `KOPIUR_CAPACITY: 30Gi`,
  `KOPIUR_ON_MISSING_SNAPSHOT: Continue` (greenfield).
- `app/kustomization.yaml` — `helmrelease.yaml`, `externalsecret.yaml`,
  `httproute.yaml`, `ciliumnetworkpolicy.yaml`.
- `app/externalsecret.yaml` —
    - `infinidysk-secret` (target): all keys from the Phase 0 table, templating the
      `NZBDAV_CONFIG__USENET__PROVIDERS` / `ARR__INSTANCES` JSON blobs (see below) and
      `API_KEY`, `WEBDAV_USER`/`WEBDAV_PASSWORD`.
    - Slim `infinidysk-webdav-secret` (target): `WEBDAV_USER` + `WEBDAV_PASSWORD` only
      — consumed by every rclone sidecar (secret split per the `idlers` lesson; the
      sidecars never need NNTP creds).
- `app/helmrelease.yaml` — app-template v5, `chartRef: OCIRepository/app-template`.
  Canonical boilerplate from `zurg/app/helmrelease.yaml` + `sonarr/app/helmrelease.yaml`:

    ```yaml
    # essentials (sketch — follow the canonical files for full shape)
    image: ghcr.io/infinidysk/infinidysk  # tag: vX.Y.Z@sha256:...
    env:
      PUID: "1000"; PGID: "1000"
      TRUST_PROXY: "1"; SECURE_COOKIES: "true"
      FRONTEND_BACKEND_API_KEY: <from infinidysk-secret API_KEY>
      NZBDAV_CONFIG__API__KEY:            <same value>
      NZBDAV_CONFIG__API__CATEGORIES: "other,radarr,radarr4k,sonarr,sonarr4k,nonplex"
      NZBDAV_CONFIG__API__MANUAL_CATEGORY: "other"
      NZBDAV_CONFIG__API__IMPORT_STRATEGY: "symlinks"
      NZBDAV_CONFIG__API__NZB_BACKUP_ENABLED: "true"       # /config holds the corpus
      NZBDAV_CONFIG__API__NZB_BACKUP_RETENTION_DAYS: "0"   # forever
      NZBDAV_CONFIG__API__ENSURE_ARTICLE_EXISTENCE_CATEGORIES: "other,radarr,radarr4k,sonarr,sonarr4k,nonplex"
      NZBDAV_CONFIG__API__ARTICLE_EXISTENCE_CHECK_MODE: "sampled"  # zurg-equivalent pre-check
      NZBDAV_CONFIG__RCLONE__MOUNT_DIR: "/aio/remote/infinidysk"   # == in-pod mount path
      NZBDAV_CONFIG__MEDIA__LIBRARY_DIR: "/aio/symlinks"
      NZBDAV_CONFIG__WEBDAV__USER: <webdav user>
      NZBDAV_CONFIG__WEBDAV__PASS: <raw secret; hashed at overlay load>
      NZBDAV_CONFIG__WEBDAV__ENFORCE_READONLY: "true"      # consumers only read the VFS
      NZBDAV_CONFIG__USENET__SEGMENT_CACHE__ENABLED: "false"  # symlink mode; restart to change
      NZBDAV_CONFIG__USENET__PROVIDERS: <JSON — see below>
      NZBDAV_CONFIG__ARR__INSTANCES: <JSON — see below>
      NZBDAV_CONFIG__REPAIR__ENABLE: "true"
      NZBDAV_CONFIG__BACKUP__SCHEDULE_ENABLED: "true"; ...  # DB self-backup; kopiur is the real DR
    service:
      app: { ports: { http: { port: 3000 }, webdav: { port: 8080 } } }
    persistence:
      config:  existingClaim: infinidysk → /config     # from components/kopiur
      symlinks: existingClaim: symlinks → /aio/symlinks
      tmp: emptyDir → /tmp
      + rclone self-mount (below)
    ```

    `NZBDAV_CONFIG__USENET__PROVIDERS` (PascalCase properties; map zurg's topology —
    zurg `backbone` ≙ InfiniDysk **Storage group**, zurg `backup: true` ≙ provider
    `Type: 3` BackupOnly, primary accounts `Type: 1` Pool Connections):

    ```json
    {
        "Providers": [
            {
                "Type": 1,
                "Host": "news.eweka.nl",
                "Port": 563,
                "UseSsl": true,
                "User": "…",
                "Pass": "…",
                "MaxConnections": 50,
                "Nickname": "eweka",
                "StorageGroup": "omicron"
            },
            {
                "Type": 1,
                "Host": "eunews.frugalusenet.com",
                "Port": 563,
                "UseSsl": true,
                "User": "…",
                "Pass": "…",
                "MaxConnections": 75,
                "Nickname": "frugal-eu",
                "StorageGroup": "frugal"
            },
            {
                "Type": 1,
                "Host": "news.frugalusenet.com",
                "Port": 563,
                "UseSsl": true,
                "User": "…",
                "Pass": "…",
                "MaxConnections": 25,
                "Nickname": "frugal-us",
                "StorageGroup": "frugal"
            },
            {
                "Type": 3,
                "Host": "bonus.frugalusenet.com",
                "Port": 563,
                "UseSsl": true,
                "User": "…",
                "Pass": "…",
                "MaxConnections": 50,
                "Nickname": "frugal-bonus"
            },
            {
                "Type": 3,
                "Host": "eunews.blocknews.net",
                "Port": 563,
                "UseSsl": true,
                "User": "…",
                "Pass": "…",
                "MaxConnections": 100,
                "Nickname": "blocknews",
                "StorageGroup": "netnews"
            }
        ]
    }
    ```

    `NZBDAV_CONFIG__ARR__INSTANCES` (four instances; sonarrs listen on **:80**,
    radarrs on **:7878**; one shared API key from `/servarr/API_KEY`):

    ```json
    {
        "SonarrInstances": [
            { "Host": "http://sonarr.media.svc.cluster.local:80", "ApiKey": "…" },
            { "Host": "http://sonarr4k.media.svc.cluster.local:80", "ApiKey": "…" }
        ],
        "RadarrInstances": [
            { "Host": "http://radarr.media.svc.cluster.local:7878", "ApiKey": "…" },
            { "Host": "http://radarr4k.media.svc.cluster.local:7878", "ApiKey": "…" }
        ],
        "QueueRules": []
    }
    ```

    **Probes** on frontend `/healthz` port 3000: startup `failureThreshold ≥ 60`
    @10s (migrations + library load), readiness 30s, liveness `tcpSocket` or `/healthz`
    30s. **Resources**: start `requests: {cpu: 100m, memory: 1Gi}`, `limits.memory: 8Gi`
    and watch actuals (zurg needed 8Gi for ~5.5k releases; the .NET heap can be capped
    later via `DOTNET_GCHeapHardLimitPercent` if it creeps). **securityContext**: try
    the zurg hardened block first (`runAsNonRoot` 1000, `readOnlyRootFilesystem: true`,
    drop ALL); the image's entrypoint does `/config` ownership repair and may need the
    radarr s6-style fallback (`fsGroup: 1000` + `SETUID/SETGID/CHOWN/DAC_OVERRIDE`)
    — verify which one boots cleanly. **Do not set `TZ`** (k8tz injects
    `Europe/Paris`; schedules use it).

    **Rclone self-mount sidecar** (`rclone-infinidysk` container): upstream's own model
    binds the WebDAV mount into the InfiniDysk container (its `/mnt` in the Compose
    example) because the Library Directory contains symlinks whose targets point at
    `<mount-dir>/.ids/...` and library-health features resolve them. In-k8s that is the
    proven sidecar pattern pointed at **itself**:
    `RCLONE_CONFIG_INFINIDYSK_URL: http://infinidysk.media.svc.cluster.local:8080/`,
    mounted at `/aio/remote/infinidysk` (hostPath `/tmp/rclone-infinidysk-self`,
    Bidirectional propagation). Flag set = the Phase 2 consumer set below. If
    verification shows InfiniDysk does not need to resolve library links, this sidecar
    can be dropped later — deploy it first, it is cheap.

- `app/httproute.yaml` — `infinidysk-480p-com` (the `components/authentik` policy
  targets `${APP}-${DOMAIN_SLUG}` = exactly this name), hostname
  `infinidysk.480p.com`, parentRef `envoy-480p-com-public`/`https`, backend
  `infinidysk:3000`; Homepage annotations (`gethomepage.dev/*`, group `Media`,
  name `InfiniDysk`) and Gatus:

    ```yaml
    gatus.home-operations.com/endpoint: |-
        url: https://infinidysk.480p.com/healthz
    ```

- `app/ciliumnetworkpolicy.yaml` — shape of `zurg/app/ciliumnetworkpolicy.yaml`
  (`app.kubernetes.io/name: infinidysk` + `instance` selector). Ingress allowlist:
  gateway `envoy-480p-com-public` (→ 3000), and (→ 8080 **and** 3000) `sonarr`,
  `sonarr4k`, `radarr`, `radarr4k`, `plex`, `jellyfin`, `bazarr`, `bazarr4k`,
  `prowlarr`, `infinidysk-debug`, `media-debug`, plus `infinidysk` itself
  (the self-mount). **A consumer missing here gets FUSE mounts that serve an empty
  tree and the rollout stalls** (bazarr lesson) — when adding a consumer later, edit
  this file in the same commit.
- Authentik — follow `docs/authentik-forward-auth.md` end to end: blueprint entries
  in `kubernetes/apps/authentik/authentik/app/blueprints/forward-auth.yaml` (provider
  `infinidysk`, `external_host: https://infinidysk.480p.com`,
  `skip_path_regex: ^/healthz$`, Application + `PolicyBinding` → Group `Media`),
  hostname added to `app/outpost-routes.yaml`, `app/referencegrant.yaml` already has
  the `media` `from` entry. Ordering matters: apply the provider **before** the
  route's SecurityPolicy exists (one commit is fine — if so, restart
  `deploy/authentik-server` proactively per the runbook and verify with its curl
  recipe expecting `302`).

**Verification**:

- `kubectl -n media get pods` — `infinidysk-…` Running/Ready; startup logs show
  migrations completing.
- Dashboard: `https://infinidysk.480p.com` → SSO → first-run admin account creation
  → Settings shows lock badges on every `NZBDAV_CONFIG__*` key.
- `kubectl -n media exec deploy/infinidysk -c rclone-infinidysk -- ls /aio/remote/infinidysk`
  shows `.ids  completed-symlinks  content  nzbs`.
- Smoke test: upload a small `.nzb` in the Queue UI (category `other`); it reaches
  Completed, `completed-symlinks/<release>` appears, and `curl`-ing a byte range
  through the WebDAV mount streams (check Overview **Active Reads**).
- `bash util/check_security_invariants.sh` passes (new allowlist entries — below),
  `flate test all -p ./kubernetes/flux/cluster` passes.

**Rollback**: delete the `infinidysk` entry from `kubernetes/apps/media/kustomization.yaml`
and revert; zurg is untouched.

**Also in this phase**: add `kubernetes/apps/media/infinidysk/app/helmrelease.yaml`
(and later `infinidysk-debug`, `infinidysk-sync-helper` files) to **both** allowlists
in `util/check_security_invariants.sh` (`privileged_allowlist`, `fuse_allowlist`) —
the rclone sidecars are `privileged: true` with `/dev/fuse`, like every other
consumer in this namespace.

---

## Phase 2 — consumer scaffold (zurg wiring untouched)

1. `media/infinidysk-debug` — clone `zurg-debug` as the canonical **writable**
   consumer-sidecar playground; only the remote name/URL/secret changes. The
   canonical consumer flag set (proven in this repo + upstream guidance):

    ```sh
    exec rclone mount infinidysk:/ /host-mount/rclone-<app>-infinidysk \
      --links \
      --dir-cache-time=20s \
      --vfs-cache-mode=full --vfs-cache-max-age=24h --vfs-cache-max-size=20G \
      --vfs-cache-poll-interval=30s \
      --buffer-size=0M --vfs-read-ahead=512M \
      --vfs-fast-fingerprint --vfs-handle-caching=0 \
      --use-cookies --no-modtime --no-checksum --allow-other --cache-dir=/cache
    ```

    - `--links` is **required** (turns `*.rclonelink` into real symlinks into `.ids`);
      it is the one flag the zurg sidecars deliberately lack.
    - env: `RCLONE_CONFIG_INFINIDYSK_TYPE: webdav`,
      `RCLONE_CONFIG_INFINIDYSK_URL: http://infinidysk.media.svc.cluster.local:8080/`,
      `RCLONE_CONFIG_INFINIDYSK_VENDOR: other`,
      `RCLONE_CONFIG_INFINIDYSK_PACER_MIN_SLEEP: "0"`, `RCLONE_CONFIG_INFINIDYSK_USER`
        - `RCLONE_CONFIG_INFINIDYSK_PASS` from `infinidysk-webdav-secret` — with the
          command obscuring first:
          `export RCLONE_CONFIG_INFINIDYSK_PASS=$(rclone obscure "$RCLONE_CONFIG_INFINIDYSK_PASS_RAW")`.
    - probes: `test -d` on a stable root entry of the tree (confirm at deploy:
      `completed-symlinks` or `nzbs`), **not** zurg's `version.txt`.
    - Plex/Jellyfin mounts use the same set **plus `--read-only`** (media-server
      consumers only read; verified safe with `--vfs-cache-mode=full`).

2. Add the `rclone-infinidysk` sidecar + persistence plumbing (fuse, cache emptyDir,
   host-tmp, hostPath `/tmp/rclone-<app>-infinidysk` → `/aio/remote/infinidysk`
   `HostToContainer`) to `sonarr`, `sonarr4k`, `radarr`, `radarr4k` **alongside**
   the existing `rclone-zurg` sidecars. Sidecars and mounts of the old world stay
   until Phase 6.
3. Confirm each \*arr still mounts `symlinks` → `/aio/symlinks` (they do) and that
   `media-debug` gains the mount too.

**Verification**: all touched pods `N/N Running` with both sidecars Ready; inside
each \*arr pod `ls /aio/remote/infinidysk` lists the tree and
`ls /aio/remote/infinidysk/completed-symlinks` lists the smoke-test release as
**symlinks** (`ls -la` → `-> …`) whose targets resolve inside the same mount.
**Rollback**: revert the commit; zurg flow unaffected.

---

## Phase 3 — \*arr cutover (one app at a time; start with `sonarr`)

Per app (`sonarr` → `sonarr4k` → `radarr` → `radarr4k`):

1. **Add the download client via the API** (as zurg-migration Phase 2 did): SABnzbd
   client `InfiniDysk`, host `infinidysk.media.svc.cluster.local`, port 3000, key
   `/infinidysk/API_KEY`, category per app (`sonarr`/`sonarr4k`/`radarr`/`radarr4k`),
   **Remove Completed: enabled**, and enable global Completed Download Handling.
   Keep the `zurg (Usenet)` client **enabled** until the app's corpus is migrated,
   then disable it (it is the rollback).
2. **Repoint the root folder(s)** to the farm (`/aio/symlinks/<tree>`), preserving
   the `plex_hd`/`plex_4k` split. Ordering correction from zurg-migration: the root
   must point at the destination **before** the grab test, and the test import must
   not cross from the rclone mount into a different filesystem while
   `copyUsingHardlinks=true` would fall back to a byte copy — here the import source
   is `completed-symlinks` and the destination the farm; the \*arrs recreate
   symlinks (altmount-era behavior), **prove it** in the grab test before scaling.
3. **Grab test** (one real grab per app): expect Queued → (article check) →
   Completed → import lands in `/aio/symlinks/<tree>/…` as a **symlink** into
   `/aio/remote/infinidysk/.ids/…`; `du` of the `symlinks` PVC stays flat; playback
   from Plex/Jellyfin works through the link. Failure mode to watch: a plain-file
   copy (millions of bytes into the farm) — abort the app's cutover if seen.
4. **Corpus migration** (bulk, per app):
    1. Copy zurg's NZB corpus out: `kubectl -n media cp` (or a debug pod) from the
       zurg PVC `nzbs/` — ~5,491 `.nzb` files, filenames are release identities,
       never rename them. (The zurg MCP `zurg_library_*` tools enumerate the live
       library for reconciliation.)
    2. Bulk-add to InfiniDysk via its SAB API (`addfile`, category = the app's
       category) in batches of ~100–200 — respect queue admission limits
       (Settings → Queue) and let article checks drain between batches. Compressed-
       archive releases will report `Failed`; collect their names instead of
       retrying.
    3. Re-import against the existing DB: run the \*arr's `DownloadedEpisodesScan` /
       `DownloadedMoviesScan` with `path` pointed at the category's completed area
       (batched) — items match their existing records and the file paths rewrite to
       the farm with symlinks. No bytes fetched; no indexer spend.
    4. **Reconcile** per tree against the zurg counts
       (`plex_hd/shows` 102, `plex_hd/movies` 434, `plex_4k/shows` 67,
       `plex_4k/movies` 401, `other` 13 as of 2026-01-10-ish in zurg-migration terms)
       and the old farm counts. Shortfalls = compressed-archive rejects + dead
       releases; those fall back to **Option A**: leave them missing and let the \*arr
       re-grab unattended (blocklisting handles expired-article failures). Turn
       automatic searching off for the app while its corpus batch runs if indexer
       load needs calming.
    5. Repeat per app; then disable the app's `zurg (Usenet)` client.

**Verification**: \*arr queue/history clean; every file path under `/aio/symlinks`;
farm `ls -la` shows symlinks only; `du --apparent-size`-vs-`du` on the farm proves
no real data; Plex/Jellyfin still play (through the old zurg paths for content not
yet cut over — expected until Phase 4).
**Rollback**: re-enable the `zurg (Usenet)` client and repoint roots back to
`__magic__` (the zurg tree is never modified by this phase).

---

## Phase 4 — Plex / Jellyfin cutover

1. Add `rclone-infinidysk` sidecars to `plex` (dual mounts like the current
   zurg+altmount state) and `jellyfin`, with `--read-only` flag sets.
2. Swap each server's library locations from `/aio/remote/zurg/__magic__/…` to the
   farm (`/aio/symlinks/plex_hd/movies` etc.) **one section at a time**. Never let a
   section scan old+new locations of the same content simultaneously (double-count
   lesson from zurg-migration Phase 4).
3. **Data-loss guard**: zurg's `plex_settings_policy: guard` used to re-assert
   `autoEmptyTrash=0`; nothing does that anymore — verify Plex's
   "Empty trash automatically after every scan" is **off** and keep the
   `docs/plex-trash-sweep.md` situation in mind when entries go missing during
   mount blips.
4. Scan cadence: enable Plex "Scan my library periodically" and a Jellyfin scheduled
   library scan (replacing zurg's push scans). Keep analysis/decode-heavy tasks
   (deep analysis, VAD) off while the corpus settles — every decoded byte is fetched
   from Usenet.
5. Jellyfin gets the farm only (its zurg sidecar retires here or in Phase 6).

**Verification**: sections converge (no duplicates, no mass-missing after scans);
direct play + seek of a 4K remux streams smoothly (watch Overview **Active Reads**
on InfiniDysk); subtitle sidecars (Phase 5) still attach.
**Rollback**: re-add the zurg locations and rescan (zurg still runs until Phase 6).

---

## Phase 5 — Bazarr + manual-NZB (`other`) pipeline

1. `bazarr` / `bazarr4k`: keep their rclone sidecars pointed at InfiniDysk
   (subtitle matching reads media through the symlink → mount; ffprobe on first
   searches pulls headers — expected). Subtitle writes land as real files beside the
   farm symlinks on the `symlinks` PVC — no zurg-style sidecar budget applies.
   Size note: posters/`.nfo`/subtitles now live on the `symlinks` PVC (10Gi,
   CephFS) where zurg budgeted 10Gi for the same metadata — if usage creeps past
   ~70%, grow `KOPIUR_CAPACITY` for `symlinks` (expand-in-place is supported).
2. Manual NZBs ( etc.): upload via the InfiniDysk Queue UI with category
   `other`, then either import by hand or port `zurg-sync-helper` as
   `media/infinidysk-sync-helper` (busybox poller: SAB history `category=other` →
   move `completed-symlinks/<release>` → `/aio/symlinks/other` via its own rclone
   mount → clear the history entry). Build it only if manual NZBs become routine;
   until then manual import is fine.

**Verification**: wanted-search pass produces `.en.srt` next to farm entries;
manual NZB lands under `/aio/symlinks/other` and plays.
**Rollback**: per-item; zurg-sync-helper still exists until Phase 6.

---

## Phase 6 — teardown (zurg + folded altmount teardown)

Only after 1–2 quiet weeks (no zurg reads in InfiniDysk's absence — confirm by
stopping zurg briefly or watching its metrics):

1. Remove `zurg` from `kubernetes/apps/media/kustomization.yaml`, then the tree
   `kubernetes/apps/media/zurg/`; same for `zurg-sync-helper`, `zurg-debug`.
2. Strip `rclone-zurg` containers + persistence blocks from the ten consumers
   (`sonarr`, `sonarr4k`, `radarr`, `radarr4k`, `plex`, `jellyfin`, `bazarr`,
   `bazarr4k`, `media-debug`, and any straggler) — careful with helm-release
   history: these apps have DBs; roll forward only (bazarr alembic lesson).
3. Fold zurg-migration Phase 5 here: drop the parked `altmount` sidecars/mounts and
   the `altmount` app (its NZB store dies with it), the old disabled \*arr clients
   (`AltMount (SABnzbd)`, `-*`, `nzbdav`), and `nzbdav`/`nzbdav-sync-helper`
   themselves if decided (they are dormant config — deleting is safe and shrinks the
   security allowlists).
4. Authentik blueprint: remove the `zurg` provider/application/binding entries and
   its outpost hostname; keep `infinidysk`'s.
5. Infisical: delete `/zurg/*` **after** confirming `/infinidysk/*` holds the NNTP
   creds (Phase 0 copied them). If zurg sponsorship ends: remove the
   `RENOVATE_HOST_RULES` ghcr credentials from `.github/workflows/renovate.yaml`
   secrets (same token as `/zurg/GHCR_*`) — **both** places, per AGENTS.md.
6. Keep the zurg `/config` PVC (kopiur snapshot) until the corpus is confirmed
   migrated; then reclaim. `docs/plex-trash-sweep.md` and the zurg `guard` notes
   become historical.

**Verification**: `kubectl get externalsecret -n media` clean; `grep -r zurg
kubernetes/apps/media` empty; flate + security-invariants pass; media stack plays.
**Rollback**: revert — zurg's manifests return to Git and redploy (its PVC/snapshots
still exist until explicitly reclaimed).

---

## Phase 7 — docs & findings

- Update [`zurg-migration.md`](./zurg-migration.md) header: Phases 4–5 superseded
  here.
- Record durable findings in `AGENTS.md` (Repository Findings): the InfiniDysk
  wiring pattern (ports 3000/8080, `NZBDAV_CONFIG__*` overlay, self-mount sidecar,
  obscured rclone pass), the compressed-archive rejection, the `Remove Completed`
  requirement, and any gotcha discovered while executing.
- Consider `docs/infinidysk.md` runbook copy if operational complexity warrants.

---

## Execution hygiene (repo rules that bite here)

- `git pull --ff-only` first; Renovate merges continuously. Conventional Commits,
  one subsystem per commit (`feat(media): …`, `feat(infinidysk): …`).
- Pin every image by digest. `util/check_security_invariants.sh` also enforces
  digest-pinned `OCIRepository`s (the shared `app-template` component already is).
- No `flux reconcile` for un-pushed commits (Flux only sees the pushed revision).
- New/changed HelmReleases: `bash util/check_drift_detection.sh` must stay green
  (no per-app `driftDetection` blocks).
- Validate every manifest change with `flate test all -p ./kubernetes/flux/cluster`
  before merging; PRs touching `kubernetes/**` run the flate CI gate.
- No `TZ` env anywhere (k8tz). Runtime IDs `1000:1000`. Homepage via annotations
    - `DNSEndpoint` via `components/dnsendpoint` (both already covered by the shape
      above — this is the App Exposure Rule).
- Gatus probes behind Authentik must use the skipped `/healthz` path; assert a real
  200 from the app (the repo's Gatus conventions table in `AGENTS.md`).

## Verification appendix (quick commands)

```sh
# SSO + outpost (expect 302)
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H 'X-Forwarded-Host: infinidysk.480p.com' -H 'X-Forwarded-Proto: https' \
  -H 'X-Forwarded-Uri: /' \
  https://infinidysk.480p.com/outpost.goauthentik.io/auth/envoy

# liveness without a session (expect 200)
curl -sS -o /dev/null -w '%{http_code}\n' https://infinidysk.480p.com/healthz

# SAB API from inside the cluster (expect JSON)
kubectl -n media run sab-probe --rm -it --image=curlimages/curl -- \
  curl -s "http://infinidysk.media.svc.cluster.local:3000/api?mode=queue&output=json&apikey=$KEY"

# import is a symlink, not a copy
kubectl -n media exec deploy/sonarr -c app -- ls -la /aio/symlinks/plex_hd/shows/<Show>/

# WebDAV tree through a consumer mount
kubectl -n media exec deploy/infinidysk-debug -c app -- ls -la /aio/remote/infinidysk/
```
