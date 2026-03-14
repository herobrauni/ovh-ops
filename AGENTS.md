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

## App Exposure Rule
- If an app has a URL and a web UI, always create a `DNSEndpoint` manifest and include it in that app's `kustomization.yaml`.
- If an app has a URL and a web UI, always add or update its entry in `kubernetes/apps/selfhosted/homepage/app/configuration.yaml`.

## Upstream Template Preference
- Prefer implementations that stay as close as possible to upstream patterns used in local template repos `./tmp/bjw-s` and `./tmp/onedr0p`.
- When adding or changing apps/features in this repo, use those two repos as primary structural and naming references unless this repository has an explicit conflicting requirement.
- Common expected adaptations from those upstream templates in this repo:
    - URLs and domains.
    - Password/secret source: use Bitwarden resources instead of 1Password equivalents.
    - Envoy names.

## Repository Findings
- Record durable repo-specific implementation findings in this file when they are discovered during work, especially when they are not obvious from the existing high-level structure. Future agents should continue updating this section with short, actionable notes.
- For multi-domain TinyAuth protection, this repo uses separate `HTTPRoute` objects per hostname/domain and then attaches a matching `SecurityPolicy` to each route. Do not assume a single generated route can be targeted per-host with `sectionName`; follow patterns like `kubernetes/apps/network/echo/app/httproute.yaml` and `kubernetes/apps/network/echo/app/securitypolicy.yaml`.
- For apps exposed with a web UI, remember the exposure trio: route manifest, `DNSEndpoint`, and homepage entry in `kubernetes/apps/selfhosted/homepage/app/configuration.yaml`.
- The shared CNPG component in `kubernetes/components/cnpg` creates the usual `${APP}-initdb-secret` and `${APP}-pguser-secret` flow and defaults to a single database named `${APP}`. Apps that can tolerate a single DB should prefer that standard path.
- CNPG cluster backups in `kubernetes/apps/dbms/cloudnative-pg/cluster` now use `ScheduledBackup.spec.method: barmanObjectStore` with the `cnpg-backups` ObjectBucketClaim/secret; do not reintroduce VolumeSnapshot or VolSync resources just to enable routine backups.
- For media namespace remote mounts backed by Decypharr WebDAV, prefer the custom CSI rclone volume pattern used in `kubernetes/apps/media/media-debug/app/helmrelease.yaml` instead of assuming a PVC such as `pvc-rclone` exists.
- Sonarr in this repo is intended to use native Postgres env configuration with the `home-operations/sonarr` image. The working pattern is to set `SONARR__POSTGRES__*` env vars from `sonarr-pguser-secret` and disable the separate log database with `SONARR__LOG__DBENABLED: "False"` so logs stay on disk/Loki.
- Do not run Flux reconcile commands for local-only manifest edits that have not been committed and pushed yet; Flux will only apply the Git revision it can fetch from the remote source.

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
