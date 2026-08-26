# kubernetes-home — Flux tree for the home cluster

Second environment in this repo, managed by its own Flux instance on the
home (rehearsal/staging) cluster. Mirrors the conventions of `kubernetes/`
(the OVH cluster) — see AGENTS.md; notable differences:

- Lean app set: cilium (tunnel mode), metrics-server, snapshot-controller,
  OpenEBS (adds the `staging-hostpath` class), internal-mode Rook Ceph,
  VolSync, staging MinIO/restic rest-servers.
- No observability stack, no gateway/ingress, no external-secrets/Infisical
  (secrets are sops-encrypted in-tree for now).
- Flux sync path: `kubernetes-home/flux/cluster` (see
  `apps/flux-system/flux-instance/app/helmrelease.yaml`).

Bootstrap order: Talos (`talos-home/`) → `task home:bootstrap:full`
(helmfile: cilium, flux-operator, flux-instance) → Flux reconciles
`flux/cluster/ks.yaml` (`cluster-apps`, path `./kubernetes-home/apps`).

Full migration context: `~/Repos/pve/docs/talos-migration.md`.
