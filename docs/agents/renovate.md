# Renovate — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when an expected update is not
happening, or when changing Renovate config/workflow.

- Renovate runs self-hosted via `.github/workflows/renovate.yaml`; its debug logs (`gh api repos/herobrauni/ovh-ops/actions/runs/<id>/logs`) are the fastest way to diagnose "why is X not updating".
- Version Talos/Kubernetes bumps with `datasource=github-releases` (`siderolabs/talos`, `kubernetes/kubernetes`) in `talos/topf.yaml` + `kubernetes/apps/system-upgrade/tuppr/upgrades/*`, NOT `datasource=docker` on `ghcr.io/siderolabs/{installer,kubelet}`. The Sidero OCI manifests carry no timestamp labels, so any `minimumReleaseAge` (default `minimumReleaseAgeBehaviour: timestamp-required`) plus `RENOVATE_INTERNAL_CHECKS_FILTER: strict` in the Renovate workflow silently blocks every update forever — the dep sits in the dashboard's "Pending Status Checks" section with `Branch ... creation is disabled because internalChecksFilter was not met` in the debug logs.
- Do not reference undefined custom datasources (a `custom.talos-factory` annotation was dead code and killed Talos updates until removed).
- Cooldown policy (`.renovaterc.json5`): 3 days for Talos/Kubernetes versions, 7 days for tools (mise, GitHub Actions), none for in-cluster app images.
- Shared components: Renovate's flux manager tracks all 7 generated app-template OCIRepository documents (`kubernetes/components/app-template/ocirepository.yaml`) — see `docs/agents/components.md`.

## GHCR credentials (dead weight)

- A retired private ghcr image was Renovate-managed via the `RENOVATE_HOST_RULES` ghcr.io docker host rule in `.github/workflows/renovate.yaml` (repo secrets `GHCR_USERNAME`/`GHCR_TOKEN`, set 2026-10-03). Those secrets hold the **same** token as the Infisical `GHCR_*` values consumed by its pull secret. The host rule is host-wide (path-scoped docker credentials don't work), so a stale token breaks ALL ghcr lookups, not only private ones.
- The image was retired 2026-10-21 and its sponsorship lapsed, so the rule and both credential stores are dead weight — **remove them once nothing else private on ghcr is pulled** (then no token rotation applies).

## `helm pull` against ghcr.io failing with 403

- `403 denied` on the token endpoint means a stale/insufficient credential in `~/.docker/config.json`, not a network block (ghcr returns 403 rather than falling back to anonymous when sent a bad token). Confirm with `curl -s -o /dev/null -w '%{http_code}' 'https://ghcr.io/token?scope=repository:bjw-s-labs/helm/app-template:pull&service=ghcr.io'` (200 = network fine), then re-run with a valid token via an isolated `DOCKER_CONFIG` dir. A working token lives in `~/.config/github/GH_TOKEN`. This does not affect flate (single Go binary, no docker config involved).
