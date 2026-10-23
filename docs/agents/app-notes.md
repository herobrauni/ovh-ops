# Per-app & image notes — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when working on idlers, litellm,
niks3, the descheduler, or when giving an s6-overlay image a security context.

## Image security-context rules

- s6-overlay images (`nousresearch/hermes-agent`, `linuxserver/*`, `syncthing/syncthing`) must NOT be given `runAsNonRoot`/`runAsUser`. They start as root to chown volumes and remap UIDs, then drop privileges themselves via `s6-setuidgid`/`su-exec`; pinning a non-root UID makes them fail with EACCES. Use pod-level `fsGroup: 1000` plus container `capabilities.add: [SETUID, SETGID, CHOWN, DAC_OVERRIDE, FOWNER]`, as `kubernetes/apps/media/radarr/app/helmrelease.yaml` does.
- Some images cannot run unprivileged at all and need the narrowest working cap set instead (idlers below). `util/check_security_invariants.sh` tracks the allowlists — new privileged pods / `/dev/fuse` users must be added there in the same commit.

## `selfhosted/idlers` (AlteredParadox my-idlers fork)

- Runs `ghcr.io/alteredparadox/my-idlers`. Its MariaDB sidecar is reachable on pod-local `127.0.0.1` and is protected by `ciliumnetworkpolicy.yaml` (closing port 3306 to the rest of the cluster). Credentials are split `idlers-app-secret` (`APP_KEY` + `DB_*`) / `idlers-db-secret` (`MYSQL_*`) — see `docs/agents/secrets.md`.
- The image is not a drop-in for the original's security context: it cannot run unprivileged (the entrypoint writes `.env.production` into the root-owned `/app`), so it runs as root with `SETUID`/`SETGID` (nginx and php-fpm drop their workers to nginx/www-data), `DAC_OVERRIDE` (`artisan config:cache`/`view:cache` run as root but write into www-data-owned `bootstrap/cache` and `storage/framework`) and `CHOWN` (the entrypoint re-chowns `/app/database`). `FOWNER` is not needed. It refuses to boot without `APP_KEY`, needs `TRUSTED_PROXIES` set (Envoy terminates TLS; without it signed YABS ingest URLs fail validation), and a `Host: <APP_URL host>` header on HTTP probes (TrustHosts 400s a bare-IP probe against a healthy app).
- PHP release practice (full log: `docs/php-critical-release-2026-10-21.md`): read `PHP_VERSION` out of the image **config blob** (`ghcr.io/v2/.../manifests/<tag>` → index → amd64 manifest → config → `Env`), never the tag — `ap.20` is a base-image-only rebuild where only ap.18's `seedboxes` pricing FK migration runs on boot (`AUTO_MIGRATE=true`); every tag up to `ap.19` runs the vulnerable 8.5.11, so rolling back past `ap.20` reintroduces both CVSS 9.2 RCEs; ap.19+ runs boot-time migrations as `www-data` through `su-exec`, which is why the `SETUID`/`SETGID`/`CHOWN` caps are load-bearing. Restore data through the kopiur populator (`docs/agents/backups.md`).

## `ai/litellm`

- Hardened (non-root) deployments MUST use the `ghcr.io/berriai/litellm-non_root` image variant — the standard `litellm` image expects root and bakes no `PRISMA_*` env, so under `runAsNonRoot` + `readOnlyRootFilesystem` the python prisma client can't resolve its query engine and the proxy crash-loops with `NotConnectedError` (while `prisma migrate deploy` still succeeds, masking it). The `litellm-database` tag series is legacy.
- Replicate upstream's hardened compose for the non_root variant: emptyDirs at `/app/cache` and `/app/migrations` plus `HOME=/tmp`, `XDG_CACHE_HOME=/app/cache`, `LITELLM_MIGRATION_DIR=/app/migrations`, `LITELLM_NON_ROOT=true`; prisma engines are baked readable at `/opt/prisma` with `PRISMA_OFFLINE_MODE=true`.
- Probes: liveness `/health/liveliness`, readiness/startup `/health/readiness` (startup needs a generous failureThreshold — first boot runs prisma migrations). `STORE_MODEL_IN_DB=True` allows adding models via the UI while Git only holds a minimal `config.yaml` anchor.
- Its Redis-compatible store comes from the shared `kubernetes/components/dragonfly` component (`litellm-dragonfly.ai.svc.cluster.local:6379`), wired through `litellm_settings.cache_params` in the embedded proxy `config.yaml` (`type: redis`, `namespace: litellm`, `ttl: 300`, `port` as quoted string) plus `enable_redis_auth_cache: true` so virtual-key auth lookups share the cache across workers/future replicas. Verify the live cache with an authenticated `GET /cache/ping` on port 4000.

## `niks3`

- Uses an in-cluster Rook Ceph ObjectBucketClaim plus `NIKS3_ENABLE_READ_PROXY=true` for public cache reads at `niks3.brauni.dev`; its write path still returns presigned URLs for `rook-ceph-rgw-proxmox-s3.rook-ceph.svc:80`, so `niks3 push` clients must run where that endpoint is reachable or the S3 endpoint must be changed/exposed.
- While using `ghcr.io/mic92/niks3:v1.4.0`, keep the Gateway route's exact-root redirect to `/index.html`; upstream added the same read-proxy-aware root behavior after v1.4.0.

## Descheduler

- The `LowNodeUtilization` balance plugin was disabled 2026-10-10 (commented out in `kube-system/descheduler/app/helmrelease.yaml`, do not blindly re-enable): on this 3-node cluster the nightly utilization dip put nodes under the 20% threshold and the plugin evicted single-replica stateful pods with nowhere better to place them — `postgres18-3` and `immich-4` (CNPG replicas) plus `patchmon-dragonfly-0` 10× each in one week, plus gatus/victoria-logs/prometheus/alertmanager — causing recurring 30–90s outages. `PodsWithLocalStorage` protection does NOT cover PVC-backed pods, only emptyDir, so every STS pod was fair game.
- Visible symptom that led here: patchmon-app liveness-killed ~nightly, because its `/health` blocks while redis is unreachable (go-redis pool dial timeouts) and app-template's default probe timeout is 1s; its probes now carry `timeoutSeconds: 5` + liveness `failureThreshold: 6` (~60s tolerance) to ride out dragonfly STS recreations without a kill.
- When diagnosing "why was this pod restarted", remember the descheduler evicts (pod recreation, container restart counter resets, STS revision unchanged) — check the descheduler stream in victoria-logs (`"Evicted pod"`) next to `container_start_time_seconds` in Prometheus before suspecting the workload.
