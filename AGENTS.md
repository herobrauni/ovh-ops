# Repository Guidelines

## Project Structure & Module Organization

This repository is GitOps infrastructure for Talos and Kubernetes.
All cluster or platform changes must be made through code in this repository; avoid manual in-cluster drift.

- `kubernetes/flux/cluster/`: Flux entrypoint and top-level reconciliation scope.
- `kubernetes/apps/`: application stacks grouped by domain/namespace.
- `kubernetes/components/`: reusable shared resources (see `docs/agents/components.md`).
- `talos/`: Talos cluster config for topf (`topf.yaml`, `secrets.sops.yaml`) with patch directories (`all/`, `control-plane/`, `worker/`).
- `bootstrap/`: initial bootstrap resources, Helmfile layers, and encrypted secrets.
- `.taskfiles/` + `Taskfile.yaml`: operational tasks for Talos/bootstrap/reconcile flows.
- `util/`: small operational checks (drift detection, security invariants).
- `docs/`: runbooks plus the `docs/agents/` topic guides (see "Topic Guides" below).

## How `kubernetes/apps` Kustomizations Work

- Flux starts from `kubernetes/flux/cluster/ks.yaml` (`Kustomization/cluster-apps`) with `spec.path: ./kubernetes/apps`.
- `cluster-apps` applies defaults to every child Flux `Kustomization` via `spec.patches` (notably `deletionPolicy: WaitForTermination`, HelmRelease install/upgrade/rollback remediation defaults, and global drift detection).
- Each namespace/domain folder (`kubernetes/apps/<namespace>/kustomization.yaml`) is a **Kustomize config** that sets `namespace: <namespace>`, includes shared `../../components/alerts`, and lists `./namespace.yaml` plus one or more app `./<app>/ks.yaml` entries.
- Each app `ks.yaml` is a **Flux Kustomization CR** (or multiple CRs) pointing at a concrete manifest path such as `./kubernetes/apps/<namespace>/<app>/app`, and usually sets `sourceRef: GitRepository/flux-system`, `targetNamespace: <namespace>`, and optional `dependsOn`, `healthChecks`, `healthCheckExprs`, `wait`.
- Each app manifest path (`app/`, `instance/`, `cluster/`, `common/`, etc.) contains a `kustomization.yaml` with the actual resources (`helmrelease.yaml`, `ocirepository.yaml`, `externalsecret.yaml`, routes, policies; app-template apps get their `OCIRepository` from `components/app-template` at the namespace layer).
- `namespace.yaml` files use `metadata.name: _`; the parent namespace Kustomize layer sets the real namespace name.

## Build, Test, and Development Commands

Use `mise` to install pinned tooling from `.mise.toml`, then run:

- `task --list`: list all available tasks.
- `task talos:generate-config`: generate Talos cluster configuration.
- `task bootstrap:full`: run the full Talos + Kubernetes bootstrap sequence.
- `task reconcile`: force Flux to reconcile from Git.
- `flate test all -p ./kubernetes/flux/cluster`: local equivalent of the CI render/validate gate.
- `bash util/check_drift_detection.sh`: verify the global `cluster-apps` drift detection patch and fail on per-app leftovers.

## Coding Style & Naming Conventions

The repo is YAML-heavy and declarative.

- Follow `.editorconfig`: 2-space indentation by default, LF endings, final newline; `*.md` and `*.sh` use 4-space indentation.
- Keep file names lowercase and hyphenated; use common manifest names like `kustomization.yaml`, `helmrelease.yaml`, and `externalsecret.yaml`.
- Format YAML, JSON, and Markdown documents using `oxfmt` via `lefthook`.
- Standardize container runtime IDs on `1000:1000` (`runAsUser`, `runAsGroup`, `fsGroup`, and `PUID`/`PGID`) unless an image has a hard requirement for a different UID/GID.
- Prefer `https://k8s-schemas.home-operations.com/` for Kubernetes and CRD `yaml-language-server` schema URLs wherever that site serves the needed schema; only fall back to other schema sources when no equivalent exists (e.g. `json.schemastore.org/kustomization` for Kustomize configs). The retired `kubernetes-schemas.brauni.dev` mirror must not be referenced anymore.
- Always pin container images by digest (`@sha256:...`). Do not use unpinned image references.

## App Exposure Rule

- If an app has a URL and a web UI, always create a `DNSEndpoint` manifest and include it in that app's `kustomization.yaml`.
- If an app has a URL and a web UI, expose it in Homepage via `gethomepage.dev/*` annotations on the app's route/ingress resources; do not add static service entries in `kubernetes/apps/selfhosted/homepage/app/configuration.yaml`.
- Tailnet-only apps intentionally skip this rule (MagicDNS naming, no public route to annotate) — see `docs/agents/networking.md`.

## Upstream Template Preference

- Prefer implementations that stay as close as possible to upstream patterns used in local template repos `./tmp/bjw-s` and `./tmp/onedr0p`, unless this repository has an explicit conflicting requirement.
- Common expected adaptations from those upstream templates: URLs and domains; secret source is Infisical ExternalSecrets instead of 1Password/Bitwarden equivalents; Envoy names.

## Secrets Management with Infisical

This repo uses Infisical (EU region) as the central secret store, accessed via external-secrets-operator.

- **ClusterSecretStore** `infisical`: `kubernetes/apps/external-secrets/external-secrets/infisical/clustersecretstore.yaml`, host `https://eu.infisical.com`, project `ovh-ops-u1ua`, environment `prod`, Universal Auth credentials bootstrapped from `bootstrap/secrets.sops.yaml`.
- **Secret path convention:** `/<app>/SECRET_NAME` per app folder — e.g. `/authentik/`, `/cloudnative-pg/<app>_postgres_{username,password}`, `/servarr/` (shared Sonarr/Radarr/Prowlarr API key), `/volsync-template/` (kopia backup credentials), `/rclone/`, `/<app>/` app-specific.

### ExternalSecret Pattern

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/external-secrets.io/externalsecret_v1.json
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

- Apps using Infisical secrets must declare `dependsOn: [{name: infisical}]` in their `ks.yaml`.
- The shared `kubernetes/components/cnpg` component pulls per-app PostgreSQL credentials from `/cloudnative-pg/${APP}_postgres_{username,password}` (see `docs/agents/components.md`).
- ExternalSecret failure modes and the Infisical EU API (create/update endpoints etc.): `docs/agents/secrets.md`.

## Common Gotchas

- app-template v5 defaults `defaultPodOptions.automountServiceAccountToken` to `false`; apps/sidecars that call the Kubernetes API (Gatus sidecar, Homepage discovery) must explicitly set it to `true` or mount a projected token.
- Do not set `TZ` manually in app manifests — k8tz (`kubernetes/apps/kube-system/k8tz/`) injects `TZ=Europe/Paris` cluster-wide via a mutating webhook.
- Do not configure CoreDNS to answer `AAAA` queries with `NXDOMAIN` globally: musl/libpq clients (e.g. `ghcr.io/home-operations/postgres-init`) can treat the failed IPv6 lookup as full hostname resolution failure. If suppressing IPv6 answers is required, return empty `NOERROR` instead.
- `kubectl exec pod -- cmd <<EOF` silently runs nothing without `-i` (kubectl doesn't attach stdin by default) — always use `kubectl exec -i` for stdin-fed commands and verify with a follow-up read.
- Do not run Flux reconcile commands for local-only manifest edits that have not been committed and pushed yet; Flux only applies revisions it can fetch from the remote source.

## Testing Guidelines

Primary validation is CI-based:

- `.github/workflows/flate.yaml` runs flate `test` (full-tree validation) and `diff` (rendered, GitHub-flavored PR comment) for PRs touching `kubernetes/**`; the local equivalent is `flate test all -p ./kubernetes/flux/cluster`.
- Ensure Kubernetes manifest changes are renderable and reconcilable before opening a PR.
- Run `bash util/check_drift_detection.sh` when editing HelmRelease resources (validates global inheritance and rejects redundant per-app blocks).

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
- **Always `git pull --ff-only` before working in this repo.** Renovate merges PRs continuously (multiple per day), so a stale local checkout silently diverges from what Flux is reconciling in-cluster. Check `git status -sb` is even with `origin/main` and that HEAD matches `kubectl get kustomization cluster-apps -n flux-system`'s applied revision before making local edits or diagnosing state.

## Topic Guides (load on demand)

Durable repo-specific findings live in `docs/agents/`, split by topic — read only the one matching what you are working on:

- `docs/agents/flux.md` — Flux/Kustomize mechanics, drift detection, `postBuild` substitution, konflate, flate. _When adding namespace/app Kustomizations or debugging reconciliation._
- `docs/agents/components.md` — what `kubernetes/components/*` provides (app-template, dnsendpoint, authentik, cnpg, dragonfly, kopiur) and each component's traps. _When adding/changing apps that consume components._
- `docs/agents/secrets.md` — ExternalSecret failure modes, credential-splitting pattern, Infisical EU API. _When creating secrets programmatically or debugging ExternalSecrets._
- `docs/agents/backups.md` — kopiur (retention, mover privileges, restore), dbms pgdumpall, VolSync removal checklist, CNPG barman backups. _When adding backups or restoring data._
- `docs/agents/authentik.md` — extAuth wiring, blueprints + importer semantics, access policies, OIDC clients, user switching. _When onboarding apps to SSO or editing blueprints._ Step-by-step migration runbook: `docs/authentik-forward-auth.md`.
- `docs/agents/gatus.md` — probe URL derivation, liveness paths behind auth, webhook probe conditions. _When adding routes or fixing red status endpoints._
- `docs/agents/media.md` — InfiniDysk + sync-helper, *arr/Bazarr/Jellyfin/Silo/Plex facts, rclone sidecar pattern. _When working in `kubernetes/apps/media/`._
- `docs/agents/networking.md` — external-dns label-filter, Envoy Gateway tuning, plex traffic policies, tailnet exposure. _When touching DNS, Gateway/Envoy or tailnet apps._
- `docs/agents/talos.md` — topf, machine-config gotchas, etcd metrics, `upgrade-k8s`/tuppr traps. _When touching `talos/` or upgrading the cluster._
- `docs/agents/ceph.md` — external Ceph topology, CephX rotation, Rook keyrings, emergency-readonly volume runbook. _When working on storage/Rook or debugging volume I/O._
- `docs/agents/kubevirt-vms.md` — VM layout, `firmware.uuid`, vendored KubeVirt/CDI operators, Hermes. _When working in `kubernetes/apps/vms/`._
- `docs/agents/renovate.md` — datasources/cooldowns, blocked-update diagnosis, GHCR credentials. _When an expected update doesn't happen or when changing Renovate config._
- `docs/agents/app-notes.md` — image security-context rules, idlers, litellm, niks3, descheduler. _When working on those apps or setting security contexts._

Other `docs/*.md` files are historical plans/upgrade logs (`docs/infinidysk-migration.md`, `docs/jellyfin-v12-upgrade.md`, `docs/php-critical-release-2026-10-21.md`, `docs/dry-improvements.md`); check their status headers before relying on them.

## Repository Findings

- When you discover durable repo-specific implementation findings during work — especially anything not obvious from the high-level structure — record them in the matching `docs/agents/*.md` topic guide (create a new one if none fits) rather than here. Keep entries short and actionable; update or delete entries once they are superseded, and prefer moving one-off incident narratives into `docs/` runbooks.
