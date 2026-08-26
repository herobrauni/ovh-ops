# Home cluster (`home`) — rehearsal & staging environment

Three mini PCs (16 GB RAM, one 512 GB SSD each) on the home infra VLAN
(`10.100.15.0/24`, OPNsense SVI `10.100.15.1`, DNS `10.100.15.11`).
This cluster is the rehearsal platform and staging store for the OVH
Proxmox→bare-metal Talos migration. Full context:
`~/Repos/pve/docs/talos-migration.md`.

## Roles by phase

1. **Rehearsal** — build the exact OVH target design at home first:
   combined control-plane/worker Talos nodes, KubeSpan mesh, Cilium tunnel
   mode (MTU 1370), ingress firewall default-deny, Rook on a raw partition,
   Flux-managed via `kubernetes-home/`.
2. **Staging** — restic repos + MinIO on the `staging` volumes receive the
   migration copies from OVH (reachable from OVH over the existing site
   WireGuard tunnels; no inbound port forwards needed).
3. **Offsite backups** — permanent post-migration backup target
   (etcd snapshots, VolSync/restic, Postgres dumps).

## Disk layout per node (512 GB SSD ≈ 476 GiB)

| Partition | Size | Purpose |
|---|---|---|
| Talos system (EFI/META/STATE/BOOT) | ~4 GiB | Talos install disk (`/dev/sda`) |
| `EPHEMERAL` (capped) | 30 GiB | `/var`, container runtime, etcd |
| `u-local-hostpath` (xfs) | 30 GiB | OpenEBS localpv rehearsal |
| `r-rook-osd` (raw) | 120 GiB | Rook OSD partition |
| `u-staging` (xfs) | 270 GiB | restic repos + MinIO drives |
| unallocated | ~22 GiB | slack |

OVH target differs only in scale: dedicated second NVMe per host holds a
whole-disk 1.7 TiB OSD; ephemeral/local-hostpath get 60/100 GiB.

## Bootstrap (first build)

```sh
# 1. One-time: generate cluster secrets (never commit plaintext)
cd talos-home
talhelper gensecret > talsecret.sops.yaml
sops encrypt -i talsecret.sops.yaml

# 2. Generate node configs (after filling in MAC addresses in talconfig.yaml)
task home:generate-config

# 3. Write the ISO / PXE-boot the minis, then apply configs
task home:bootstrap:full   # insecure apply + kube bootstrap + helmfile + flux
# or manually:
talhelper gencommand apply --extra-flags '--insecure' | bash
talhelper gencommand bootstrap | bash

# 4. Fetch kubeconfig into ./kubeconfig-home
talosctl -n 10.100.15.61 kubeconfig .
```

The bootstrap helmfile (`kubernetes-home/bootstrap/`) installs Cilium
(tunnel mode), flux-operator and flux-instance; Flux then reconciles
`kubernetes-home/apps` (metrics-server, snapshot-controller, OpenEBS, Rook,
staging MinIO, VolSync).

## Notes & gotchas

- **KubeSpan** needs cluster discovery (Talos default: `discovery.talos.dev`).
  The firewall allows UDP 51820 from anywhere — required if a mini later
  joins the OVH cluster temporarily as a 4th etcd member.
- **Cilium MTU 1370**: vxlan (−50) over the KubeSpan WireGuard link (−80).
- **Volume patches only apply before first provisioning** — the disk layout
  must be in the config at install time. Changing it later requires a reset.
- **Ingress firewall**: first apply via `--mode=try` or you can lock yourself
  out; `apid` is only reachable from `10.100.15.0/24`.
- **Restoring to factory**: `task home:reset` (destroys the node's disks).
