# Talos & cluster upgrades — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when generating/applying Talos
config, upgrading Talos/Kubernetes, or debugging machine-config drift.

## topf

- `task talos:generate-config` renders configs with `topf render`; day-2 operations run through topf (`task talos:apply`, `task talos:diff`, `task talos:upgrade`, `task talos:reset`). topf intentionally does not manage Kubernetes upgrades; `task talos:upgrade-k8s` shells out to `talosctl upgrade-k8s` reading versions from `talos/topf.yaml`.
- Config generation was migrated from talhelper (archived) to topf (postfinance/topf), following onedr0p/cluster-template's structure: `topf.yaml` + `secretsPath: secrets.sops.yaml` + per-node `data:` consumed by Go-templated `.yaml.tpl` patches instead of `node/<host>/` directories.
- Always diff a migrated/changed patch file against the old patch _and_ the upstream template, not just the rendered config — silently-dropped top-level keys don't fail render or validate (this is how the `cluster.etcd` document was lost).

## Machine-config gotchas (Talos v1.14 multi-document format)

The patches use typed documents (`Kube*Config`, `SysctlConfig`, `ResolverConfig`, `CRICustomizationConfig`, `UnattendedInstallConfig`, `SecurityProfileConfig`, `Filesystem*Config`). Notes that bite:

- A 1.14-format config is rejected by 1.13 nodes (`"UnattendedInstallConfig": not registered`), so a Talos upgrade must complete before `topf apply` converges the migrated config.
- `topf`'s 1.14 base does NOT disable kube-proxy (its 1.13 base did) — `control-plane/00-cluster.yaml` must keep `KubeProxyConfig enabled: false` for the Cilium kube-proxy replacement.
- CoreDNS is Helm/Flux-managed (`kubernetes/apps/kube-system/coredns`), so the machine config must keep `KubeCoreDNSConfig enabled: false` (see the upgrade-k8s trap below).
- `SecurityProfileConfig workloadIsolation: false` is pinned explicitly because topf's 1.14 base defaults to `true`, which would break KubeVirt/Rook/node-exporter host access.
- `machine.kubelet.disableManifestsDirectory` has no typed-config equivalent and was dropped (cluster-template does the same).
- `talos/all/71-filesystem.yaml` adds the weekly `FilesystemScrubConfig` (XFS metadata check); the weekly `FilesystemTrimConfig` already renders from the topf base — do not add a second trim document, duplicate typed-config documents of the same kind are rejected.

## etcd metrics document (easy to silently lose)

- The v1alpha1 `cluster.etcd` patch document must live in `talos/control-plane/00-cluster.yaml` (upstream cluster-template carries it as the _first_ document). Without `etcd.extraArgs.listen-metrics-urls: http://0.0.0.0:2381`, etcd binds metrics to nothing reachable and every `kube-etcd` Prometheus target goes `connection refused` → `TargetDown`/`etcdMembersDown`/`etcdInsufficientMembers` alerts while etcd itself is perfectly healthy.
- `topf apply` in `auto` mode persists new etcd args with NO_REBOOT but does NOT restart etcd — the flag only takes effect after a node reboot (or etcd restart); reboot CP nodes one at a time via `talosctl -n <ip> reboot`.

## `talosctl upgrade-k8s` deletes the helm-managed CoreDNS

- Talos v1.14.1 `talosctl upgrade-k8s` (run via tuppr on Renovate k8s bumps) **deletes the helm-managed CoreDNS objects** (Deployment, `Service/kube-dns`, ClusterRole/Binding, CM, SA) when `KubeCoreDNSConfig enabled: false` — it deletes cleanly and (with Talos coredns disabled) never reapplies, causing a **cluster-wide DNS outage** until helm-controller's next reconcile (6h outage on 2026-09-26). This is on top of the older selector-mismatch failure mode (Talos' own CoreDNS manifest uses a bare `k8s-app: kube-dns` selector while the Helm Deployment's also carries `app.kubernetes.io/*` labels; Deployment selectors are immutable). Same reasoning as kube-proxy: Talos must not reconcile deployments it does not own.
- Mitigation: coredns HelmRelease `spec.interval: 5m` (drift detection is inherited from the global `cluster-apps` patch — see `docs/agents/flux.md`) — note **helm-controller v1.5.3's CRD has no `driftDetection.interval`** (schema rejects it and stalls the Kustomization), so the short spec.interval is the supported cap. A post-`upgrade-k8s` `flux reconcile helmrelease coredns` hook and/or a CoreDNS-down PrometheusRule would close the gap further.

## tuppr upgrades

- A tuppr `KubernetesUpgrade`/`TalosUpgrade` that exhausts its job backoffLimit goes `Failed` terminally and will not retry on its own. After fixing the underlying cause, retrigger with `kubectl -n system-upgrade annotate kubernetesupgrade kubernetes tuppr.home-operations.com/reset="$(date)"` (same for `talosupgrade`); the re-run is a no-op fast-path when the actual node work already completed.
