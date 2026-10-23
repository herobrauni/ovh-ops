# KubeVirt, CDI & VMs — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when working in
`kubernetes/apps/vms/`, or when re-vendoring the KubeVirt/CDI operators.

## VM layout

- VMs live in the `vms` namespace, one Flux Kustomization per VM following the same three-layer model as apps. The namespace must keep `pod-security.kubernetes.io/enforce: privileged` because both `virt-launcher` and the CDI importer pods need it.
- A VM Kustomization's `healthCheckExprs` on `status.ready` legitimately fails during CDI import; set `retryInterval: 1m` so it self-heals instead of waiting out the full interval.
- The `smoke-test` Alpine VM validates the platform end to end — including a 5-second PreCopy live migration between workers — and should be removed once Hermes is settled on a VM.
- VM disks intended for live migration should use the virtualization-default `ceph-block-kubevirt` StorageClass and CDI StorageProfile, which provision RWX raw RBD block volumes with only the `layering` image feature and a `Retain` reclaim policy.

## cloud-init: `firmware.uuid` is load-bearing

- KubeVirt uses `spec.domain.firmware.uuid` as the cloud-init `instance-id` (`cloudInitUUIDFromVMI` in `pkg/cloud-init/cloud-init.go`). If a VM has a `firmware` block without an explicit `uuid`, virt-api pins a generated one, every restart reuses the same instance-id, and cloud-init silently skips all per-instance modules (users, ssh keys, packages, runcmd) — changed user-data never applies. Always set `firmware.uuid` explicitly and bump it to a fresh UUID whenever cloud-init user-data changes.
- Symptom seen here: hostname from meta-data applied, ssh key rejected, no `AgentConnected` condition, while the same image + noCloud.iso boots correctly under local qemu from a fresh disk.

## Guest networking

- Guests with masquerade networking are reached through the virt-launcher pod IP (inbound DNAT to 10.0.2.15). `virtctl ssh`'s embedded golang ssh client rejects valid keys where the real `ssh` binary succeeds — use `kubectl port-forward` to the launcher pod (or a Service selecting `kubevirt.io/domain: <vm>`) plus the real ssh client instead.
- The cluster pod network is IPv4-only, so guests get no routable IPv6 (only `fec0::` site-local auto-addrs); use Tailscale inside a guest if tailnet v6 is needed.

## Vendored operators (KubeVirt + CDI)

- KubeVirt and CDI are installed from vendored upstream operator manifests under `kubernetes/apps/kubevirt` and `kubernetes/apps/cdi`; there is no official upstream Helm chart. Runtime images are overridden with digest-pinned operator environment variables.
- When Renovate bumps only the component images (`operator/images.yaml`), the vendored RBAC can lag the operator version: a new KubeVirt minor may grant itself permissions its own vendored ClusterRole does not hold (e.g. v1.9.0 introduced `plugin.kubevirt.io`), and the API server's RBAC escalation guard rejects the update with `is forbidden: ... attempting to grant RBAC permissions not currently held`, stalling the upgrade as `DeploymentFailed`. Fix by re-vendoring `operator.yaml` from the matching upstream release (drop the leading Namespace doc, keep the vendored-from header, format with `oxfmt`); a version mismatch between the vendored file header and the image env vars is the tell-tale sign.
- The vendored `network-policies.yaml` files restrict egress for `virt-api`, `virt-handler`, `virt-exportproxy`, `cdi-deployment` and `cdi-uploadproxy` without allowing the Kubernetes API server or DNS (upstream assumes an OpenShift-style guaranteed path). On this Cilium/kube-proxy-replacement cluster those pods crash-loop with `dial tcp 10.43.0.1:443: i/o timeout` until the companion `ciliumnetworkpolicy.yaml` in each operator layer (`toEntities: kube-apiserver` + kube-dns 53) unions the missing egress back in. When re-vendoring, keep the companion CNP in sync with whatever egress-restricted pod labels the new netpol set selects.

## Hermes

- When Hermes Agent runs as a container, its `state.db` is SQLite in WAL mode and must stay on a block-backed RWO volume (`ceph-block`), never CephFS. If Hermes moves into KubeVirt, the database may live on the guest's local ext4 filesystem backed by the VM's raw RBD disk; the Kubernetes-side RWX mode is then used only for migration handoff. (Container images: s6-overlay rule applies — `docs/agents/app-notes.md`.)
