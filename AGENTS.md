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

## App Exposure Rule
- If an app has a URL and a web UI, always create a `DNSEndpoint` manifest and include it in that app's `kustomization.yaml`.

## Upstream Template Preference
- Prefer implementations that stay as close as possible to upstream patterns used in local template repos `./tmp/bjw-s` and `./tmp/onedr0p`.
- When adding or changing apps/features in this repo, use those two repos as primary structural and naming references unless this repository has an explicit conflicting requirement.
- Common expected adaptations from those upstream templates in this repo:
    - URLs and domains.
    - Password/secret source: use Bitwarden resources instead of 1Password equivalents.
    - Envoy names.

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
