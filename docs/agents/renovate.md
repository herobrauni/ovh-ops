# Renovate — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when an expected update is not
happening, or when changing Renovate config/workflow.

- Renovate runs self-hosted via `.github/workflows/renovate.yaml`; its debug logs (`gh api repos/herobrauni/ovh-ops/actions/runs/<id>/logs`) are the fastest way to diagnose "why is X not updating".
- Talos/Kubernetes versions are bumped via `# renovate: datasource=github-releases depName=siderolabs/talos` in `talos/topf.yaml` and via the `custom.talos-factory` annotation on `system-upgrade/tuppr/upgrades/talosupgrade.yaml`. `custom.talos-factory` **is** defined — the `apps/talosFactory.json5` preset this repo extends maps it to `https://factory.talos.dev/versions`; do not "clean up" that annotation, it is what keeps Talos patch releases flowing (latest: `v1.14.7`, #1911).
- `system-upgrade/tuppr/upgrades/kubernetesupgrade.yaml` still uses `datasource=docker depName=ghcr.io/siderolabs/kubelet` and that path works again (v1.37.2 → v1.37.3 landed in #1927). If kubelet updates ever stall in "Pending Status Checks", it is the Sidero OCI manifests carrying no timestamp labels that trip `minimumReleaseAge` (default `minimumReleaseAgeBehaviour: timestamp-required`) together with `RENOVATE_INTERNAL_CHECKS_FILTER: strict` in the Renovate workflow — then either switch that annotation to `github-releases` on `siderolabs/talos` or relax the cooldown.
- Do not reference datasources that no preset defines; a lookup failure shows up as "Package lookup failures" on the dashboard, not as a failed job.
- Cooldown policy (`.renovaterc.json5`): 3 days for Talos/Kubernetes versions, 7 days for tools (mise, GitHub Actions), none for in-cluster app images.
- Shared components: Renovate's flux manager tracks all 7 generated app-template OCIRepository documents (`kubernetes/components/app-template/ocirepository.yaml`) — see `docs/agents/components.md`.

## GHCR credentials (dead weight)

- A retired private ghcr image was Renovate-managed via the `RENOVATE_HOST_RULES` ghcr.io docker host rule in `.github/workflows/renovate.yaml` (repo secrets `GHCR_USERNAME`/`GHCR_TOKEN`, set 2026-10-03). Those secrets hold the **same** token as the Infisical `GHCR_*` values consumed by its pull secret. The host rule is host-wide (path-scoped docker credentials don't work), so a stale token breaks ALL ghcr lookups, not only private ones.
- The image was retired 2026-10-21 and its sponsorship lapsed, so the rule and both credential stores are dead weight — **remove them once nothing else private on ghcr is pulled** (then no token rotation applies).

## Image pin pitfalls (audited 2026-11-27)

- **Always pin `tag@sha256:…`.** A digest-only reference (`image: holmes@sha256:…`) has no `currentValue`, so Renovate logs `Could not determine new digest for update` and the pin never moves — holmesgpt's Holmes/holmes-operator images silently stayed at 0.45.0 while the chart went 0.47.0. Add the tag (found by matching the pinned digest against the registry's tag list) to restore tracking.
- **Avoid `latest@sha256:…`.** Immutable but version-blind: Renovate can only do digest bumps, so the pin drifts with nothing to reason about (`bentopdf`, `firefly3`, `opencloudeu/radicale` still use it). Prefer the real release tag whose digest equals the pin — `GET /v2/<repo>/manifests/<tag>` returns `Docker-Content-Digest` for comparison.
- **Verify the repository still exists** before trusting a green pod: `ghcr.io/home-operations/bazarr4k` answers `NAME_UNKNOWN` on `/tags/list` and 404s by digest, yet the pods keep running off cached containerd layers. An upstream rename/retirement looks identical to a healthy deployment until the pod reschedules.
- `config:recommended` does not pin Dockerfile base images; `.renovaterc.json5` pins them explicitly for `images/**` (`matchManagers: ["dockerfile"]`, `pinDigests: true`), so keep `images/*/Dockerfile` refs fully qualified (`tag@sha256`).

## `helm pull` against ghcr.io failing with 403

- `403 denied` on the token endpoint means a stale/insufficient credential in `~/.docker/config.json`, not a network block (ghcr returns 403 rather than falling back to anonymous when sent a bad token). Confirm with `curl -s -o /dev/null -w '%{http_code}' 'https://ghcr.io/token?scope=repository:bjw-s-labs/helm/app-template:pull&service=ghcr.io'` (200 = network fine), then re-run with a valid token via an isolated `DOCKER_CONFIG` dir. A working token lives in `~/.config/github/GH_TOKEN`. This does not affect flate (single Go binary, no docker config involved).
