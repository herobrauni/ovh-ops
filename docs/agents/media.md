# Media stack — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when working on anything in
`kubernetes/apps/media/`. Background plans/phase logs: `docs/infinidysk-migration.md`,
`docs/jellyfin-v12-upgrade.md`.

## Storage architecture

- InfiniDysk is the media download backend (Usenet/NZB via a SABnzbd-compatible API); import strategy is `symlinks`, and the consumer farm lives on the `symlinks` PVC mounted at `/aio/symlinks` (plex_hd, plex_4k, other, …). Media servers read the farm; subtitle sidecars write next to the farm symlink.
- Remote mounts use **rclone sidecar containers co-located in each app pod** (not a CSI driver): the sidecar runs `rclone mount` with `Bidirectional` mount propagation on a host `/tmp` path; the app container picks the mount up via `HostToContainer` propagation. Mount lifecycle ties to the app pod and mount failures surface as sidecar probe failures that block the pod. Canonical pattern: `kubernetes/apps/media/sonarr/app/helmrelease.yaml` / `media/media-debug/app/helmrelease.yaml`.
- rclone's password obfuscation is **not deterministic**, so sidecars take the raw WebDAV password and run `rclone obscure` in their entrypoint instead of keeping a second stored copy.
- s6-overlay images (`linuxserver/*`, `syncthing/syncthing`, …) must NOT get `runAsNonRoot`/`runAsUser` — see `docs/agents/app-notes.md`.

## InfiniDysk (`media/infinidysk`)

Two processes: frontend `:3000` (admin UI, SABnzbd API, `/api`, `/ws` — the only port published through the Gateway) and backend `:8080` (WebDAV). Facts that are not obvious from the manifests:

1. rclone must connect to **8080 directly** — proxying through 3000 costs throughput and makes the UI log an operator warning.
2. Every Git-owned setting is an `NZBDAV_CONFIG__*` env var (the "headless" overlay: `api.import-strategy` → `NZBDAV_CONFIG__API__IMPORT_STRATEGY`). An **unknown key aborts startup**, and so does an unknown _property_ inside the structured JSON blobs (`usenet.providers`, `arr.instances`, …) whose property names are PascalCase. The config is therefore **not forward compatible**: rolling back to an older image after adopting a new property fails to boot instead of ignoring it.
3. The entrypoint must start as root: it creates the `PUID`/`PGID` user, repairs `/config` ownership and `su-exec`s to UID 1000, so `readOnlyRootFilesystem` cannot be enabled (`adduser` writes `/etc`); the narrow cap set `SETUID/SETGID/CHOWN` is the compensating control (see the helmrelease).
4. `rclone.mount-dir` must be **identical** in the pod and every consumer (symlink targets embed it) — hence no remote path mappings. InfiniDysk also resolves library symlinks for health/repair, so it runs a **loopback self-mount** (`http://127.0.0.1:8080/`, same pod netns) at `/aio/remote/infinidysk`.
5. `webdav.enforce-readonly` is deliberately unset — the *arrs delete the import source after a symlink move and clean up completed entries.
6. InfiniDysk **rejects compressed RAR/7z payloads** (only stored/`m0` archives and direct media stream), so older RAR-packed items fail their SAB job and fall back to an *arr re-grab.
7. There is no Plex/Jellyfin push-scan integration — both servers need periodic library scans.
8. Consumer sidecars need `--links` (turns `*.rclonelink` into real symlinks into `.ids`) — which the retired backend's sidecars specifically lacked. **Every new consumer must be added to `media/infinidysk/app/ciliumnetworkpolicy.yaml` in the same commit**, or its FUSE mount serves an empty tree and stalls the rollout.
9. The main database is PostgreSQL: `DATABASE_PROVIDER=postgres` + `DATABASE_CONNECTION_STRING` (ADO.NET form `Host=…;Port=5432;Database=…;Username=…;Password=…`), from `/cloudnative-pg/infinidysk_postgres_*` (role+DB on `postgres18`) with a `postgres-init` initContainer. Its DB secrets are defined **locally** rather than via `components/cnpg`, because composing the component's discrete `host`/`port`/`db`/`user` keys into one connection string inside the pod does not work — app-template renders `env` in **sorted key order**, so `DATABASE_CONNECTION_STRING` resolves before `PGPORT` and `$(VAR)` placeholders reach Npgsql literally (`System.FormatException: Couldn't set port`). Patch targets also can't reach component output from an app-level `kustomization.yaml` (and a `spec.patches` entry in `ks.yaml` would collide with the globally injected drift-detection patch).
10. PostgreSQL main-DB support is **new-install only** — the app refuses to start if `/config/db.sqlite` already exists, and there is no SQLite→PostgreSQL migration (delete the file while stopped). Only the _main_ store moves: `metrics.sqlite`, `warden.db`, the NZB corpus and `blobs/` stay on `/config` (kopiur covers those) while the PG database needs its own `pg_dump` backup.
11. `arr.instances` hosts must use port **80**: all four *arr Services expose 80 (the Radarrs map `80 -> 7878` via `targetPort`), so `radarr:7878` from another pod times out instead of failing fast.
12. InfiniDysk owns the full provider allowances (150 primaries + the two metered fill accounts, set in `infinidysk/app/externalsecret.yaml`).
13. Probes: frontend has `/api` health endpoints; `media/media-debug` is the canonical consumer (busybox + `rclone-infinidysk` sidecar + `symlinks` PVC at `/aio/symlinks` — one shell shows source tree and consumer view; it's the canary where sidecar flag changes land first).
14. Sign-in is **native OIDC** (frontend ≥0.10.0, PKCE authorization-code), not forward auth: `OIDC_ISSUER`/`_CLIENT_ID`/`_REDIRECT_URI`/`_SCOPES`/`_USERNAME_CLAIM`/`_ADMIN_CLAIM{,_VALUE}` are plain **frontend process** env vars (not `NZBDAV_CONFIG__*`), the client secret comes from `/infinidysk/OIDC_CLIENT_SECRET` through `envFrom`, and the host has no `components/authentik` SecurityPolicy, no `outpost-routes.yaml` entry and no proxy provider (retired by `blueprints/infinidysk-oidc.yaml`). Consequences: a partial config disables OIDC instead of failing the pod (local admin login is the break-glass), the **whole frontend including the SABnzbd API is internet-reachable up to app auth** (API key / session — the extAuth hop used to hide it), and role mapping is `groups` `Platform` = admin vs read-only for everyone else, which the docs call a UI role and explicitly _not_ a security boundary.
15. The OIDC redirect URI is **pinned** to `https://infinidysk.480p.com/auth/oidc/callback` in both the app env and the provider (`matching_mode: strict`); the route is fixed in the frontend (`frontend/server/oidc-routes.ts`), and leaving it to `general.base-url` only adds a proxy-header dependency. `OIDC_ISSUER` needs the trailing slash — authentik's discovery document hangs off `…/application/o/infinidysk/`.

## `media/infinidysk-sync-helper` (manual NZBs)

A busybox poller with a **read-only** `rclone-infinidysk` sidecar (`--links`, `--read-only`, VFS cache off) and the `symlinks` PVC: for every SAB history slot with `status: Completed` (category `other`) it recreates the release's symlinks under `/aio/symlinks/other/` and clears the job with `del_files=0`. Replaces `zurg-sync-helper` + `altmount-sync-helper`. Traps:

1. Clearing the history entry also removes `completed-symlinks/<category>/<release>`, so the farm copy is created and every link verified to resolve **before** the clear — the farm link is what keeps the release library-linked for health/repair and out of Remove Orphaned Files. A farm copy that is short or has a non-resolving link is removed and retried while its job stays.
2. `mode=history` ignores `limit` (because `api.ignore-history-limit` is on), so every slot must be processed — polling only the newest one stalls behind a Downloading item.
3. Slots arrive as one compact `},{`-joined line, and a `read` loop over a split without a terminating newline silently drops the last (newest) slot — 33 slots parsed as 32 once. Keep the trailing-newline handling.
4. `DRY_RUN=1` / `CLEAR_JOBS=0` place links without touching history (first run against an untrusted backend).
5. Its ingress (3000 + 8080) lives in `media/infinidysk/app/ciliumnetworkpolicy.yaml` like every other consumer, and it is allowlisted in both `util/check_security_invariants.sh` lists.
6. After a pass that placed something it refreshes Jellyfin's `Other` library (`POST /Items/<id>/Refresh?Recursive=true`, library id resolved by name from `/Library/MediaFolders` at runtime). `POST /Library/Media/Updated` is a 204 no-op for that library (`EnableRealtimeMonitor` off in its `options.xml`), and Jellyfin 12 accepts only `Authorization: MediaBrowser Token="<key>"` (`X-Emby-Token` and `?api_key=` are 401). The token is `/jellyfin/API_KEY` in Infisical (admin-scoped); a failed refresh is a WARN that never blocks placement.

## *arr apps

- The builds here (sonarr/sonarr4k `5.0.0.2742`, prowlarr `2.10.1`) ship Servarr's `AllowedHostsCheck` health warning when `AllowedHosts` is empty and `AuthenticationRequired` is not `Enabled` (the Radarr images predate the check). Fix: `SONARR__SERVER__ALLOWEDHOSTS` / `PROWLARR__SERVER__ALLOWEDHOSTS` = `<public-host>,<app>.media.svc.cluster.local`, and then **every** `httpGet` probe needs `httpHeaders: [{name: Host, value: <app>.media.svc.cluster.local}]` — kubelet sends `Host: <podIP>:<port>` and the filter 400s it, so probes without the override restart-loop the pod. Verified against the live image: allowed names → 200/302, pod IP/unknown hosts → 400, `Host: localhost` still allowed. Flipping `AUTH__REQUIRED: Enabled` only _silences_ the health check while `AUTH__METHOD: External` is in play — cosmetic, not a fix.
- Sonarr uses native Postgres env configuration with the `home-operations/sonarr` image: `SONARR__POSTGRES__*` from `sonarr-pguser-secret` plus `SONARR__LOG__DBENABLED: "False"` so logs stay on disk/Loki.
- Shared Servarr API key: only apps that pass the key straight to an env var consume the shared `media/servarr-secret` (`servarr` ExternalSecret, key `API_KEY`); apps that template config files from it (bazarr, bazarr4k, warrden) keep their own ExternalSecret because ESO templates cannot read another Secret.

## Bazarr + Bazarr4K (subtitle grabbers)

English-only profiles writing `.en.srt` sidecars into the farm via their own privileged rclone sidecars. Hard requirements:

1. The rclone sidecar needs **both** the persistence scaffolding AND its container definition — a missing container silently yields an empty `/aio/remote/infinidysk` (hostPath `DirectoryOrCreate`): `system/health` "root directory not accessible" + wanted-search jobs dying on unhashable files.
2. The backend CNP gates ingress per app label — a pod not on the allowlist gets FUSE mounts that serve an empty tree and block every lookup (the `version.txt` sidecar probe hangs), stalling the rollout past the helm-controller 5m timeout → rollback.
3. A rollback AFTER the app already ran DB migrations breaks the older image with alembic `Can't locate revision '<new>'` — always roll forward (`flux reconcile helmrelease --force`).
4. Stale FUSE mounts under `/tmp/rclone-bazarr*-infinidysk` ("transport endpoint is not connected") block the _app_ container's CreateContainer before the sidecar (whose `umount -l` would heal it) can start — clear with a privileged busybox pod mounting hostPath `/tmp` with `mountPropagation: Bidirectional` and `umount -l`.
5. New pods must be added to `util/check_security_invariants.sh`'s `privileged_allowlist` (the FUSE one already covers them).
6. Provider creds: `opensubtitlescom` (username/password from Infisical `/opensubtitles/{USERNAME,PASSWORD}`) is seeded in both `externalsecret.yaml` config seeds; `subf2m` requires a browser-like `user_agent` or it config-errors into a 12h throttle; `titlovi` has no creds and just stays throttled (harmless). Apply live via `POST /api/system/settings` (form keys `settings-<section>-<field>`) + `POST /api/providers?action=reset`.
7. **The default language profile must be stored as the profile _id_, not its name.** Bazarr 1.6.x dropped the Sonarr-side guard, so `serie_default_profile: English` makes every **new** series insert `profileId='English'` and die with `sqlite3.IntegrityError: FOREIGN KEY constraint failed`; the Radarr path kept its guard and silently inserts movies with `profileId=NULL` (never searched). Store `1`. Fixing an existing install: `POST /api/system/settings` with `settings-general-serie_default_profile=1&settings-general-movie_default_profile=1`; assign the profile to every row that missed it (`POST /api/series?seriesid=…&profileid=1`, `POST /api/movies?radarrid=…&profileid=1`, plain repeated params — NO `[]` suffix, bracketed params are silently ignored by flask reqparse and still return 204 — batches of 40); then force the missing-subtitle recompute by re-posting the existing profile JSON as `languages-profiles=…` to `POST /api/system/settings`, otherwise episodes keep `missing_subtitles=NULL` and nothing is ever searched.
8. Wanted searches are `PATCH /api/{series,movies}?action=search-wanted` (global) or per-item `action=search-missing`; `use_embedded_subs: true` means first searches also ffprobe each file through the mount (slow backlog; knowit/mediainfo TypeErrors on exotic remuxes are non-fatal).
9. The global re-index tasks `series_full_scan_subtitles` / `movies_full_scan_subtitles` (daily 04:00, trigger via `POST /api/system/tasks?taskid=…`) must run after any backend/source change so embedded tracks are re-detected.
10. Both Bazarrs need the `symlinks` PVC mounted at `/aio/symlinks` **read-write**: paths in the DB are the farm (`/aio/symlinks/plex_*`), `series_download_subtitles()` opens with `os.path.exists(...)` and raises a bare `OSError` (logged as `Exception raised while running function:` with no message) for every series without it, and the `.srt` belongs beside the farm symlink. Transient `sqlite3.OperationalError: database is locked` during the first big series sync self-heals.

## Jellyfin (`media/jellyfin`)

Runs the **JPVenson/Jellyfin.Pgsql fork** (upstream has the pluggable `IJellyfinDatabaseProvider` layer but ships only SQLite; the fork author only supports latest→latest upgrades). Runbook: `docs/jellyfin-v12-upgrade.md`. Durable facts:

1. Two code migrations are PostgreSQL-incompatible and get skipped via pre-inserted `__EFMigrationsHistory` rows: `20260910120000_MigrateRatingLevels` (iterates a deferred `IQueryable` while `ExecuteUpdate`-ing on the same connection — Npgsql rejects it; the `release-12.z` rename `20260915120000` has the SAME bug, so every future fork bump that adds a new RatingLevels copy needs its history row re-checked) and `20260911120000_StripEmbeddedLinkedChildren` (uses SQLite `json_valid()` in raw SQL). If a boot loops with `Attempt to rollback JellyfinDb` → `PostgreSQL restore from PgsqlBackups/...`, a migration failed and the fork restored its own pre-migration dump — skip the routine; the restored DB is not lost data.
2. Migration passes can take 20–45 min (path-based cleanup stats every item over the mount), so the startup probe needs a huge budget while on a new major (`failureThreshold: 600`; revert after the post-upgrade scans). Probe kills keep committed removal batches; failure→restore cycles discard them.
3. Jellyfin 12 serves a styled 503 startup page (`server: Kestrel`) on web routes while `/System/Info/Public` already answers 200 — don't debug the gateway when the server is just mid-startup.
4. 12.1 rejects `<EncoderPreset xsi:nil="true" />` in `encoding.xml` (XML parse error per boot); set a concrete value (`veryfast`).
5. Library locations are the farm (`/aio/symlinks/{plex_hd,plex_4k,other}`); only the `rclone-infinidysk` sidecar is active.

## Silo (`media/silo`)

Silo media server (`ghcr.io/silo-server/silo-server`, Go + Postgres + Redis, pre-1.0), wired next to jellyfin/plex: `components/cnpg` (shared `postgres18`, DB/role `silo`), `components/dragonfly` (`REDIS_URL=redis://silo-dragonfly.media.svc.cluster.local:6379`; optional in `integrated` mode, required once a transcode/proxy node is added) and `components/kopiur` for `/var/lib/silo`. Facts that bite:

1. Migrations open with `CREATE EXTENSION IF NOT EXISTS vector` and **pgvector is not a trusted extension**, so the app's own role gets `permission denied to create extension "vector"`. `postgres-init` only runs `/initdb/<dbname>.sql` as the CNPG superuser **when it creates the database** (that's what the `silo-initdb` ConfigMap is for) — if the DB is ever created by hand, run the statement before Silo starts. `pg_trgm`/`citext` are trusted and need no help.
2. `POSTGRES_TUNE` must stay `off`: Silo applies pgtune through `ALTER SYSTEM`, which a shared-cluster app role cannot do.
3. Ports are fixed in-container (`PORT` 8080 web/native API, `JF_PORT` 8096 Jellyfin/Emby compat, 13378 Audiobookshelf beta, not exposed); the compat listener gets its own hostname (`silo-jf.480p.com`) because JF ecosystem clients take a per-service address. Probes: `/api/v1/health` (no dependency checks) and `/api/v1/ready` (gates on Postgres only) — both anonymous.
4. It runs as 1000:1000 but **without** `readOnlyRootFilesystem`: the runtime Jellyfin Web installer shells out to `npm ci && npm run build:production`, which needs a writable `HOME` (`/tmp`).
5. Like every InfiniDysk consumer it needs its label in `media/infinidysk/app/ciliumnetworkpolicy.yaml` and both `util/check_security_invariants.sh` allowlists in the same commit.
6. It is a Go binary, so **the runtime ignores the cgroup memory limit** unless `GOMEMLIMIT` is set: the heap grows until the cap and the kernel kills the container mid-scan (OOMKilled at 3.92GiB of a 4Gi limit). Silo reads the detected limit only to size its image-cache worker pool. Keep `GOMEMLIMIT` ~2GiB under the limit — plugin subprocesses (`silo.tvdb`, `silo.tmdb`, `silo.auth.oidc`), transient `ffprobe` per episode and page cache all share the cgroup but not the Go heap.
7. Its OIDC provider lives in `blueprints/silo-oidc.yaml` — see `docs/agents/authentik.md` for the OAuth2 blueprint traps.

## Plex

- The plex HTTPRoute uses named rules with `X-Plex-Http-Pipeline: infinite` set on **every** rule plus two route-level BackendTrafficPolicies — see `docs/agents/networking.md` for the Envoy-side details.
- **Pending:** nothing re-asserts `autoEmptyTrash: 0` on the Plex server any more (the retired backend's `plex_settings_policy: guard` did), so when Plex's libraries move fully to the InfiniDysk farm, verify "Empty trash automatically after every scan" is off by hand.

## Retired backends (zurg/altmount)

- The zurg/altmount apps and their helpers were removed from the repo on 2026-10-23 (the migration that replaced them: `docs/infinidysk-migration.md`). Their operational notes were deliberately not kept — git history has them if ever needed.
