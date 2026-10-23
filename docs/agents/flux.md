# Flux, Kustomize & PR tooling — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when adding namespace/app
Kustomizations, debugging reconciliation, or working on PR-render tooling.

## Layout mechanics

- `kubernetes/apps/` has NO root `kustomization.yaml`; the Flux kustomize-controller auto-generates one and reconciles the namespace subdirectories recursively. New namespace folders are picked up by `cluster-apps` simply by existing — do not add an apps-root kustomization, and note plain `kustomize build kubernetes/apps` fails locally while Flux/flate succeed.
- `cluster-apps` (`kubernetes/flux/cluster/ks.yaml`) applies defaults to every child Flux `Kustomization` via `spec.patches` (notably `deletionPolicy: WaitForTermination`, HelmRelease install/upgrade/rollback remediation defaults, and drift detection).
- Do not run Flux reconcile commands for local-only manifest edits that have not been committed and pushed yet; Flux will only apply the Git revision it can fetch from the remote source.

## Drift detection

- `driftDetection: mode: enabled` is injected globally by `cluster-apps` (it patches every child Kustomization's `spec.patches` with a HelmRelease patch); per-app `driftDetection` blocks are redundant and an app-level `mode: disabled` cannot override it. Drift is repaired at each HelmRelease's own `spec.interval` — hence coredns's 5m. The patch only reaches HelmReleases applied by children of `cluster-apps` (all of them: no namespace-layer `kustomization.yaml` references a `helmrelease.yaml` directly — don't add one).

## postBuild substitution

- Flux `postBuild.substituteFrom` sources (e.g. `kopiur-sftp-config`) must live in a **different** Kustomization than the one consuming them: Flux resolves substitution at build time, before anything is applied, so a same-Kustomization producer deadlocks `BuildFailed` forever.

## konflate (in-cluster PR diff rendering)

- `flux-system/konflate` renders PR diffs in-cluster. It is deliberately single-instance (`strategy: Recreate`, `replicaCount` 0 or 1 only — a second replica wedges on the RWO cache PVC) and its `/hooks` HTTPRoute is intentionally NOT behind auth: konflate verifies the GitHub webhook HMAC itself via `KONFLATE_WEBHOOK_SECRET`, and GitHub cannot complete an extAuth redirect. The UI/API route is Authentik-protected.
- Auth is GitHub App based (`config.appClientId` + `/konflate/KONFLATE_APP_PRIVATE_KEY` in Infisical — the same CI bot App the runners use; installation tokens cover reads, `Konflate` status checks and PR comments, so no PATs are stored).
- PR re-renders are instant once the repo webhook points at `https://konflate.brauni.dev/hooks`, otherwise the 15m `refreshInterval` backstop applies.

## Validation

- `.github/workflows/flate.yaml` runs flate `test` (full-tree validation) and `diff` (rendered, GitHub-flavored PR comment) for PRs touching `kubernetes/**`; the local equivalent of the CI gate is `flate test all -p ./kubernetes/flux/cluster` (single static binary, renders the whole repo in seconds).
- `bash util/check_drift_detection.sh` verifies the global `cluster-apps` drift detection patch and fails on per-app leftovers; run it when editing HelmRelease resources.
