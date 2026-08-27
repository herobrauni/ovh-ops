# Repository Guidelines

## Project Structure & Module Organization
This repository is GitOps infrastructure for Talos and Kubernetes.
All cluster or platform changes must be made through code in this repository; avoid manual in-cluster drift.
- `kubernetes/flux/cluster/`: Flux entrypoint and top-level reconciliation scope.
- `kubernetes/apps/`: application stacks grouped by domain/namespace.
- `kubernetes/components/`: reusable shared resources (alerts, volsync, etc.).
- `talos/`: Talos cluster config (`talconfig.yaml`, `talenv.yaml`) and machine patches.
- `bootstrap/`: initial bootstrap resources, Helmfile layers, and encrypted secrets.
- `.taskfiles/` + `Taskfile.yaml`: operational tasks for Talos/bootstrap/reconcile flows.
- `util/`: small operational checks (for example drift detection).

## How `kubernetes/apps` Kustomizations Work
- Flux starts from `kubernetes/flux/cluster/ks.yaml` (`Kustomization/cluster-apps`) with `spec.path: ./kubernetes/apps`.
- `cluster-apps` applies defaults to every child Flux `Kustomization` via `spec.patches` (notably `deletionPolicy: WaitForTermination` and HelmRelease install/upgrade/rollback remediation defaults).
- Each namespace/domain folder (`kubernetes/apps/<namespace>/kustomization.yaml`) is a **Kustomize config** that:
    - sets `namespace: <namespace>`
    - includes shared `../../components/alerts`
    - includes `./namespace.yaml` and one or more app `./<app>/ks.yaml` entries
- Each app `ks.yaml` is a **Flux Kustomization CR** (or multiple CRs) that points to a concrete manifest path such as `./kubernetes/apps/<namespace>/<app>/app` and usually sets:
    - `sourceRef: GitRepository/flux-system`
    - `targetNamespace: <namespace>`
    - optional `dependsOn`, `healthChecks`, `healthCheckExprs`, and `wait`
- Each app manifest path (`app/`, `instance/`, `cluster/`, `common/`, etc.) contains a `kustomization.yaml` that is standard Kustomize resource composition (`helmrelease.yaml`, `ocirepository.yaml`, `externalsecret.yaml`, routes, policies, etc.).
- `namespace.yaml` files use `metadata.name: _`; the parent namespace Kustomize layer sets the real namespace name.

When adding or changing apps under `kubernetes/apps`, preserve this three-layer model:
1. Namespace-level `kustomization.yaml` wires namespace + app `ks.yaml` entries.
2. App-level `ks.yaml` defines Flux reconciliation behavior and ordering.
3. App subdirectory `kustomization.yaml` defines the actual Kubernetes manifests.

## Build, Test, and Development Commands
Use `mise` to install pinned tooling from `.mise.toml`, then run:
- `task --list`: list all available tasks.
- `task talos:generate-config`: generate Talos cluster configuration.
- `task bootstrap:full`: run the full Talos + Kubernetes bootstrap sequence.
- `task reconcile`: force Flux to reconcile from Git.
- `bash util/check_drift_detection.sh`: verify HelmRelease drift detection coverage.

## Coding Style & Naming Conventions
The repo is YAML-heavy and declarative.
- Follow `.editorconfig`: 2-space indentation by default, LF endings, final newline.
- `*.md` and `*.sh` use 4-space indentation.
- Keep file names lowercase and hyphenated; use common manifest names like `kustomization.yaml`, `helmrelease.yaml`, and `externalsecret.yaml`.
- Preserve `.yamlfmt.yaml` conventions when formatting YAML documents.
- Standardize container runtime IDs on `1000:1000` (`runAsUser`, `runAsGroup`, `fsGroup`, and `PUID`/`PGID`) unless an image has a hard requirement for a different UID/GID.
- Prefer `https://kubernetes-schemas.brauni.dev/` for Kubernetes and CRD `yaml-language-server` schema URLs wherever that site serves the needed schema; only fall back to other schema sources when no `brauni.dev` equivalent exists.
- Always pin container images by digest (`@sha256:...`). Do not use unpinned image references.

## App Exposure Rule
- If an app has a URL and a web UI, always create a `DNSEndpoint` manifest and include it in that app's `kustomization.yaml`.
- If an app has a URL and a web UI, expose it in Homepage via `gethomepage.dev/*` annotations on the app's route/ingress resources; do not add static service entries in `kubernetes/apps/selfhosted/homepage/app/configuration.yaml`.

## Upstream Template Preference
- Prefer implementations that stay as close as possible to upstream patterns used in local template repos `./tmp/bjw-s` and `./tmp/onedr0p`.
- When adding or changing apps/features in this repo, use those two repos as primary structural and naming references unless this repository has an explicit conflicting requirement.
- Common expected adaptations from those upstream templates in this repo:
    - URLs and domains.
    - Password/secret source: use Infisical ExternalSecrets instead of 1Password/Bitwarden equivalents.
    - Envoy names.

## Secrets Management with Infisical
This repo uses Infisical (EU region) as the central secret store, accessed via external-secrets-operator.

### ClusterSecretStore
- **Name:** `infisical`
- **Location:** `kubernetes/apps/external-secrets/external-secrets/infisical/clustersecretstore.yaml`
- **Host:** `https://eu.infisical.com`
- **Project:** `ovh-ops-u1ua`, environment `prod`
- **Auth:** Universal Auth credentials bootstrapped from `bootstrap/secrets.sops.yaml`

### Secret Path Convention
Secrets are organized by app folder: `/<app-name>/SECRET_NAME`. Common paths:
- `/authentik/` — Authentik identity provider
- `/cloudnative-pg/` — Per-app PostgreSQL credentials (for example `/cloudnative-pg/sonarr_postgres_username`)
- `/servarr/` — Shared API key for Sonarr/Radarr/Prowlarr
- `/volsync-template/` — Kopia backup repository credentials
- `/rclone/` — Rclone remote mount credentials
- `/<app>/` — App-specific secrets

### ExternalSecret Pattern
When adding an app that needs secrets, create `externalsecret.yaml` following this template:

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.brauni.dev/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app>
spec:
  refreshInterval: 12h
  secretStoreRef:
    kind: ClusterSecretStore
    name: infisical
  target:
    name: <app>-secret
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        ENV_VAR_NAME: "{{ .SECRET_KEY }}"
  data:
    - secretKey: SECRET_KEY
      remoteRef:
        key: /<app>/SECRET_NAME
```

### Flux Dependency
Apps using Infisical secrets must declare the dependency in their `ks.yaml`:
```yaml
spec:
  dependsOn:
    - name: infisical
```

### Reusable Components
The shared `kubernetes/components/cnpg` component uses variable substitution (`${APP}`) to pull per-app PostgreSQL credentials from `/cloudnative-pg/${APP}_postgres_username` and `/cloudnative-pg/${APP}_postgres_password`.

## Repository Findings
- Record durable repo-specific implementation findings in this file when they are discovered during work, especially when they are not obvious from the existing high-level structure. Future agents should continue updating this section with short, actionable notes.
- For multi-domain TinyAuth protection, this repo uses separate `HTTPRoute` objects per hostname/domain and then attaches a matching `SecurityPolicy` to each route. Do not assume a single generated route can be targeted per-host with `sectionName`; follow patterns like `kubernetes/apps/network/echo/app/httproute.yaml` and `kubernetes/apps/network/echo/app/securitypolicy.yaml`.
- For apps exposed with a web UI, prefer annotation-driven Homepage discovery (`gethomepage.dev/*`) on route/ingress resources plus a `DNSEndpoint`; do not rely on static Homepage `services.yaml` entries.
- app-template v5 defaults `defaultPodOptions.automountServiceAccountToken` to `false`; apps/sidecars that call the Kubernetes API (for example Gatus sidecar and Homepage discovery) must explicitly set it to `true` or mount a projected token.
- The shared CNPG component in `kubernetes/components/cnpg` creates the usual `${APP}-initdb-secret` and `${APP}-pguser-secret` flow and defaults to a single database named `${APP}`. Apps that can tolerate a single DB should prefer that standard path.
- CNPG cluster backups in `kubernetes/apps/dbms/cloudnative-pg/cluster` now use `ScheduledBackup.spec.method: barmanObjectStore` with the `cnpg-backups` ObjectBucketClaim/secret; do not reintroduce VolumeSnapshot or VolSync resources just to enable routine backups.
- When bootstrapping a replacement CNPG cluster from an object-store backup while keeping backup archiving enabled, do not point the new cluster at the same Barman archive path/server lineage as the source backup. Use a fresh backup destination (for example `.../v2/`) or another unique server name, otherwise recovery can fail with `Expected empty archive` during the WAL archive safety check.
- For media namespace remote mounts, this repo uses rclone sidecar containers co-located in each app pod (not a separate CSI driver). The sidecar runs `rclone mount` with `Bidirectional` mount propagation on a host `/tmp` path; the app container picks up the mount via `HostToContainer` propagation. This ties the mount lifecycle directly to the app pod: app restart → mounts restart, and mount failures surface as sidecar probe failures that block the pod. See `kubernetes/apps/media/sonarr/app/helmrelease.yaml` or `kubernetes/apps/media/media-debug/app/helmrelease.yaml` for the canonical pattern.
- Sonarr in this repo is intended to use native Postgres env configuration with the `home-operations/sonarr` image. The working pattern is to set `SONARR__POSTGRES__*` env vars from `sonarr-pguser-secret` and disable the separate log database with `SONARR__LOG__DBENABLED: "False"` so logs stay on disk/Loki.
- Large VolSync Kopia restores in this repo can exceed the default cache EmptyDir size and get evicted with `Usage of EmptyDir volume "cache" exceeds the limit`. The shared `kubernetes/components/volsync/replicationdestination.yaml` should keep a larger `spec.kopia.cacheCapacity` (currently `32Gi`) unless an app has a smaller proven requirement.
- The shared `kubernetes/components/volsync` PVC template currently names the restored/managed claim `${APP}` and does not consume `VOLSYNC_CLAIM`; workloads using that component should mount the `${APP}` claim name unless the component itself is changed.
- Do not run Flux reconcile commands for local-only manifest edits that have not been committed and pushed yet; Flux will only apply the Git revision it can fetch from the remote source.
- For the goauthentik/authentik Helm chart, setting `serviceAccount.create: false` alone makes server/worker pods fall back to the namespace's default ServiceAccount. If you do not need managed outpost RBAC, create a dedicated minimal ServiceAccount with `automountServiceAccountToken: false` and set both `server.serviceAccountName` and `worker.serviceAccountName` explicitly.
- Authentik was moved from the long-lived `gh-sdko-oauth-account-selection` development image to official `2026.8.0-rc6` on 2026-08-05. The development database was ultimately discarded and recreated cleanly under RC6, so it no longer contains rewritten/fake-applied PR-branch migration history or the stale tenant setup flag. The legacy Infisical `AUTHENTIK_SECRET_KEY` contains base64 line wrapping; keep stripping newlines in the Authentik ExternalSecret template because the RC6 Rust embedded outpost uses that key as an HTTP bearer value and rejects control characters.
- Ceph `osd.1` was manually reweighted to `0.96002` on 2026-04-26 with `ceph osd reweight-by-utilization 105 0.02 2 --no-increasing` to relieve nearfull pressure while old CNPG S3 backups age out. Recheck after backup cleanup and normalize `osd.1` back toward `1.00000` if utilization allows.
- Do not configure CoreDNS to answer `AAAA` queries with `NXDOMAIN` globally. Musl/libpq clients (for example `ghcr.io/home-operations/postgres-init`) can treat the failed IPv6 lookup as full hostname resolution failure and stay stuck waiting for PostgreSQL. If suppressing IPv6 answers is required, return empty `NOERROR` instead.
- Niks3 uses an in-cluster Rook Ceph ObjectBucketClaim plus `NIKS3_ENABLE_READ_PROXY=true` for public cache reads at `niks3.brauni.dev`; its write path still returns presigned URLs for `rook-ceph-rgw-proxmox-s3.rook-ceph.svc:80`, so `niks3 push` clients must run where that endpoint is reachable or the S3 endpoint must be changed/exposed. While using `ghcr.io/mic92/niks3:v1.4.0`, keep the Gateway route's exact-root redirect to `/index.html`; upstream added the same read-proxy-aware root behavior after v1.4.0.
- Do not set `TZ` env var manually in app manifests. k8tz (`kubernetes/apps/kube-system/k8tz/`) injects `TZ=Europe/Paris` cluster-wide via a mutating webhook. Manual `TZ` overrides create inconsistency and should be removed.
- Tailnet-only apps intentionally skip the "App Exposure Rule" (`DNSEndpoint` + Homepage annotations). That rule presumes a public Envoy route on `brauni.dev`; apps exposed solely through the tailscale-operator get their name from MagicDNS and have no public route to annotate. Layer 3 uses `spec.type: LoadBalancer` + `spec.loadBalancerClass: tailscale` on the Service (app-template v5 templates all three fields); layer 7 uses a standalone Ingress with `ingressClassName: tailscale` and `spec.tls[].hosts`.
- `kubernetes-schemas.brauni.dev` is generated by `.github/workflows/schemas.yaml`: a daily (cron + `workflow_dispatch`) job extracts every CRD installed in the live cluster into `<group>/<lowercase-kind>_<version>.json` and publishes to Cloudflare Pages. Consequences: (1) a schema URL for a CRD that is not installed yet serves the HTML index with HTTP 200 — check the response body is JSON, not just the status code; (2) new CRDs (e.g. from a fresh KubeVirt/CDI install) only get real schemas after the CRDs reconcile and the next Schemas run — trigger it manually with `gh workflow run Schemas` after merging; (3) the site serves CRDs only, so built-in kinds (Namespace, Deployment, RoleBinding, StorageClass, ...) must keep their `json.schemastore.org/kube-*` fallback URLs.
- VMs live in the `vms` namespace (`kubernetes/apps/vms/`), one Flux Kustomization per VM following the same three-layer model as apps. The namespace must keep `pod-security.kubernetes.io/enforce: privileged` because both `virt-launcher` and the CDI importer pods need it. A VM Kustomization's `healthCheckExprs` on `status.ready` legitimately fails during CDI import; set `retryInterval: 1m` so it self-heals instead of waiting out the full interval. The `smoke-test` Alpine VM (`kubernetes/apps/vms/smoke-test/`) exists to validate the platform end to end — including a 5-second PreCopy live migration between workers — and should be removed once Hermes is settled on a VM.
- KubeVirt and CDI are installed from their vendored upstream operator manifests under `kubernetes/apps/kubevirt` and `kubernetes/apps/cdi`; there is no official upstream Helm chart. Runtime images are overridden with digest-pinned operator environment variables. VM disks intended for live migration should use the virtualization-default `ceph-block-kubevirt` StorageClass and CDI StorageProfile, which provision RWX raw RBD block volumes with only the `layering` image feature and a `Retain` reclaim policy.
- The vendored KubeVirt/CDI `network-policies.yaml` files restrict egress for `virt-api`, `virt-handler`, `virt-exportproxy`, `cdi-deployment` and `cdi-uploadproxy` without allowing the Kubernetes API server or DNS (upstream assumes an OpenShift-style guaranteed path). On this Cilium/kube-proxy-replacement cluster those pods crash-loop with `dial tcp 10.43.0.1:443: i/o timeout` until the companion `ciliumnetworkpolicy.yaml` in each operator layer (`toEntities: kube-apiserver` + kube-dns 53) unions the missing egress back in. When re-vendoring either operator, keep the companion CNP in sync with whatever egress-restricted pod labels the new netpol set selects.
- When Hermes Agent runs as a container, its `state.db` is SQLite in WAL mode and must stay on a block-backed RWO volume (`ceph-block`), never CephFS. If Hermes moves into KubeVirt, the database may live on the guest's local ext4 filesystem backed by the VM's raw RBD disk; the Kubernetes-side RWX mode is then used only for migration handoff.
- s6-overlay images (`nousresearch/hermes-agent`, `linuxserver/*`, `syncthing/syncthing`) must NOT be given `runAsNonRoot`/`runAsUser`. They start as root to chown volumes and remap UIDs, then drop privileges themselves via `s6-setuidgid`/`su-exec`; pinning a non-root UID makes them fail with EACCES. Use pod-level `fsGroup: 1000` plus container `capabilities.add: [SETUID, SETGID, CHOWN, DAC_OVERRIDE, FOWNER]`, as `kubernetes/apps/media/radarr/app/helmrelease.yaml` already does.
- `selfhosted/idlers2` runs the AlteredParadox my-idlers fork (`ghcr.io/alteredparadox/my-idlers`) beside the original `selfhosted/idlers` (`ghcr.io/herobrauni/my-idlers`). Isolation is structural, not credential-based: each has its own pod, its own MariaDB sidecar reachable only on pod-local `127.0.0.1`, and its own PVC, and neither MariaDB is published through a Service — so both deliberately consume the same `/idlers/*` Infisical values. The fork's migration set is a strict superset of the original's (identical through `2023_09_20_121309`, then 18 more), so the instance was seeded by restoring a `mariadb-dump` of the original into the new database and letting `AUTO_MIGRATE=true` migrate it forward; the imported migrations stay batch 1 and the fork's additions land as batch 2. Repeat that ordering — import first, migrate second — for any further rebuild.
- `idlers2` splits its credentials into `idlers2-app-secret` (`APP_KEY` + `DB_*`) and `idlers2-db-secret` (`MYSQL_*`) so the internet-facing PHP container never receives the MariaDB root password it has no use for. Prefer this split for any app-plus-database-sidecar pod; `selfhosted/idlers` still uses the older single-secret shape and would benefit from the same treatment. Note that a missing `remoteRef` fails the *entire* ExternalSecret rather than one key, and these workloads use the `Recreate` strategy, so referencing an Infisical key before it exists takes the app down instead of stalling the rollout — confirm the key exists first (a throwaway ExternalSecret templating `{{ .KEY | len }}` proves it without revealing the value).
- The AlteredParadox my-idlers image is not a drop-in for the original's security context. It cannot run unprivileged — the entrypoint writes `.env.production` into the root-owned `/app` — so it runs as root with the narrowest working cap set: `SETUID`/`SETGID` (nginx and php-fpm drop their workers to the nginx/www-data users), `DAC_OVERRIDE` (`artisan config:cache`/`view:cache` run as root but write into www-data-owned `bootstrap/cache` and `storage/framework`), and `CHOWN` (the entrypoint re-chowns `/app/database`). `FOWNER` was tried and is not needed. It also refuses to boot without `APP_KEY` and needs `TRUSTED_PROXIES` set (Envoy terminates TLS; without it signed YABS ingest URLs fail validation) and a `Host: <APP_URL host>` header on HTTP probes (TrustHosts 400s a bare-IP probe against a healthy app).
- If `helm pull` against `ghcr.io` fails with `403 denied` on the token endpoint (which makes `flux-local test --enable-helm` fail for every OCI-chart app at once), the cause is a stale/insufficient credential in `~/.docker/config.json`, not a network block. ghcr returns 403 rather than falling back to anonymous when it is sent a bad token. Confirm with `curl -s -o /dev/null -w '%{http_code}' 'https://ghcr.io/token?scope=repository:bjw-s-labs/helm/app-template:pull&service=ghcr.io'` (200 = network fine), then re-run with a valid token via an isolated `DOCKER_CONFIG` dir. A working token lives in `~/.config/github/GH_TOKEN`. Full local gate: `DOCKER_CONFIG=<dir> flux-local test --enable-helm --all-namespaces --path kubernetes/flux/cluster`.

## Testing Guidelines
Primary validation is CI-based:
- `.github/workflows/flux-local.yaml` runs Flux Local `test` and `diff` for PRs touching `kubernetes/**`.
- Ensure Kubernetes manifest changes are renderable and reconcilable before opening a PR.
- Run focused checks locally via Task commands and `util/check_drift_detection.sh` when editing HelmRelease resources.

## Commit & Pull Request Guidelines
History follows Conventional Commits (for example `feat(network): ...`, `fix(echo): ...`).
- This is a GitOps-driven repo: every intended environment change must be represented as committed manifests/config in Git.
- Use `type(scope): summary` where scope matches the changed area.
- Keep commits focused to one subsystem/path.
- PRs should include: concise purpose, impacted paths, rollout/risk notes, and linked issue when applicable.

## Security & Configuration Tips
- Never commit plaintext secrets or credentials.
- Store secrets as `*.sops.yaml` and decrypt only via configured `SOPS_AGE_KEY_FILE`/`age.key`.
- Treat `kubeconfig` and Talos client config as sensitive files.
