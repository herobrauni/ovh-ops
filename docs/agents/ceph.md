# Ceph & Rook (external cluster) — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when working on storage, Rook,
CephX keys, or debugging volume I/O failures.

The cluster consumes an **external** Ceph on Proxmox (the mon address and fsid live in the `rook-ceph` configuration and Infisical, deliberately not in Git); Rook runs in external mode and also owns
`cephObjectStores` (RGW) on that cluster.

## Topology

- The external cluster announces ALL mon + OSD addresses on the provider's **public network**; Talos VMs (per-host `k8s` bridge `10.10.8.0/24`, `.1` on every PVE host) reach it **SNAT'd through their PVE host's public IP** (`POSTROUTING SNAT --to-source <pve-public-ip>`), not via a vRack — `10.10.8.0/24` is stitched cross-host only by the WG/BGP mesh for k8s traffic and overlaps on every host, so it is NOT usable as a Ceph network.
- A silent TCP kill on that path fails in-flight krbd ops with `result -108` (ESHUTDOWN) in node dmesg, leaves NO trace in Ceph (`ceph -s` HEALTH_OK, OSDs/mons up, no blacklist, no auth failures, empty logs, clean conntrack), and any ext4 fs that was mid-write goes `emergency_ro` (see below). One-off so far. If it recurs: correlate the alert timestamp with PVE-host conntrack/dmesg, any firewall reloads on the SNAT host, and CephX rotation history (a rotated-away key turns the next reconnect into a hard failure — kernel clients keep the map-time key until remap).

## CephX key rotation runbook

`create-external-cluster-resources.py --cephx-key-rotate rotate --cephx-key-type aes256k` rotates ONLY the script-managed CSI users (`csi-rbd-node/.N`, `csi-rbd-provisioner/.N`, `csi-cephfs-node/.N`, `csi-cephfs-provisioner/.N`) and the read-only `client.healthchecker`:

1. Update `/rook-ceph/CSI_*_SECRET` in Infisical from the JSON output and force-sync the ExternalSecrets: `kubectl annotate externalsecret -n rook-ceph <name> force-sync=$(date +%s) --overwrite`.
2. The operator user `client.rook-admin` (Infisical `ROOK_EXTERNAL_USERNAME`/`ROOK_EXTERNAL_USER_SECRET`) is manually created, NOT touched by the script, and must stay admin-cap because external mode + `cephObjectStores` has Rook create pools/the RGW user on the external cluster — do NOT replace it with the script's `client.healthchecker` output. Rotate it manually with `ceph auth rotate client.rook-admin --key-type=aes256k` (caps are preserved; plain `ceph auth rotate` uses the cluster-preferred cipher).
3. After updating `ROOK_EXTERNAL_USER_SECRET` in Infisical and force-syncing the `rook-ceph-mon` ExternalSecret, the rook operator does NOT pick up the new key on its own: it keeps its keyring at `/var/lib/rook/rook-ceph/client.<user>.keyring` (pod-local) and keeps authenticating with the stale rotated-away key — `handle_auth_bad_method server allowed_methods [2] and I support [2,1]` + `RADOS permission denied` in `deploy/rook-ceph-operator` logs is the tell-tale signature. `kubectl -n rook-ceph rollout restart deploy/rook-ceph-operator` rebuilds the keyring from the Secret and heals it.
4. The RGW daemon user `client.rgw.proxmox.s3.a` is the last un-rotated credential consumed from this cluster: its keyring lives in the operator-generated k8s Secret `rook-ceph-rgw-proxmox-s3-a-keyring` (ns `rook-ceph`, type `kubernetes.io/rook` — NOT in Infisical, do not turn it into an ExternalSecret). To rotate: `ceph auth rotate client.rgw.proxmox.s3.a --key-type=aes256k` on the Proxmox host, patch the k8s Secret's `keyring` field with the new key (same keyring format, caps preserved), then `rollout restart deploy/rook-ceph-rgw-proxmox-s3-a`.
5. aes256k CSI keys are empirically fine on Talos 6.18.48 kernels (RBD krbd map + CephFS kernel mount both verified 2026-09-14; Rook docs' "kernel 7.0+" is conservative); Rook docs still mandate ceph-csi ≥ v3.17.1 for aes256k.

Full aes256k migration checklist for the external cluster lives in the CephX Config Reference (auth-config-ref): rotate clients → let rotating service keys expire (2–3h TTL; `ceph auth wipe-rotating-service-keys` exists but is discouraged) → drop `aes` from the mon `auth_allowed_ciphers` / `mon_auth_allow_insecure_key` settings to enforce secure-only. The cluster still warns `14 auth client entities with insecure key types` (remaining Proxmox-side users on old aes keys) — cosmetic for now, but mons still _allow_ insecure keys.

## Legacy-key auth rejection (ceph v20.2.4)

- The external PVE cluster on ceph v20.2.4 rejects legacy-key (`AQ…` aes) client auth outright (`mon_auth_allow_insecure_key=false` default; mon log: `AuthRegistry … failed to pick con mode from client's [1] and our []`). The rook operator's **mon-secret** path (`rook-ceph-mon` secret ← Infisical `/rook-ceph/ROOK_EXTERNAL_MONITOR_SECRET`) fails with `exit status 13` every ~8 min (disruption/OSD-metadata checks) while health polling keeps working via `client.rook-admin` (aes256k) — so `CephCluster HEALTH_OK` stays plausible and the breakage is invisible. Fix: patch the Infisical value to the same `Ag…` key as `ROOK_EXTERNAL_USER_SECRET`, force-sync the ExternalSecret, restart the operator (errors stop after its in-memory ClusterInfo refreshes, ~20 min). Also deleted the unreferenced manual `rook-ceph/ceph-admin-keyring` secret (dead legacy key).
- Presenting a key via `--id <user>` must NOT include the `client.` prefix (double-prefix gives a confusing `couldn't find entity name` auth failure).

## Running the ceph CLI inside the operator pod

- `CEPH_CONF` is the ONLY env knob that makes the binary read the operator-generated config — `CEPH_ARGS="--conf ..."` is silently ignored (`error calling conf_read_file`), and without an explicit identity the CLI ends up "no keyring found; disabled cephx authentication" → exit 13 as `client.` itself. Working invocation:

    ```sh
    kubectl -n rook-ceph exec deploy/rook-ceph-operator -- sh -c \
      'CEPH_CONF=/var/lib/rook/rook-ceph/rook-ceph.config ceph -n client.rook-admin --keyring=/var/lib/rook/rook-ceph/client.rook-admin.keyring <cmd>'
    ```

    The keyring/config are rebuilt at pod start from the `rook-ceph-mon` secret — their pod-local timestamps tell you whether a restart picked up a rotated key.

- `ceph time-sync-status` is a bare command, not `ceph ceph time-sync-status`; skew-driven `HEALTH_WARN` (MON_CLOCK_SKEW > 0.05s on a Proxmox mon) self-heals as NTP converges — check the per-mon `skew` values trending down before treating it as an infra fault.

## Open item

- Ceph `osd.1` was manually reweighted to `0.96002` on 2026-04-26 with `ceph osd reweight-by-utilization 105 0.02 2 --no-increasing` to relieve nearfull pressure while old CNPG S3 backups age out. Recheck after backup cleanup and normalize `osd.1` back toward `1.00000` if utilization allows.

## Emergency-readonly volumes (ext4 `emergency_ro`)

Seen 2026-09-27 (one app first, five sibling PVCs on another worker hit silently): a path failure mid-write leaves ext4 `emergency_ro` while the workload keeps running read-only for days logging `attempt to write a readonly database` (3203 ops in one second, one rbd device only, other nodes' dmesg clean).

Diagnosis:

- Map the kernel rbdN → image via the PV's `spec.csi.volumeAttributes.imageName` (pool from volumeAttributes), then from the PVE side `rbd -p kubeblock status <csi-vol-…>` — **`Watchers: none` while the image is still mapped = stale client session, the smoking gun**. `rbd info` shows the parent snapshot chain (clones read through it).

Heal (pod delete alone is NOT reliable — the CSI staged globalmount survives a pod recreation and the new pod bind-mounts the same emergency_ro ext4):

1. `kubectl scale deploy <app> --replicas=0`
2. Wait until the volume's `csi-vol-*` name disappears from `/sys/bus/rbd/devices/*/name` on the node.
3. Scale back up — the fresh stage+mount replays the journal rw. Victims heal even with the on-disk error flag set (verified on five victims; only altmount had noisy I/O, the others ran read-only unnoticed until the probe caught them).

Beware false "still read-only" readings: exec touch as the app user can hit EACCES (linuxserver `ubuntu` user vs `nobody`-owned ephemeral `/config` root) — distinguish from EROFS and probe the actual PVC mountpoint.

Alerting: `node_filesystem_readonly` does NOT see emergency_ro (VFS stays `rw`, 6.18 ext4 refuses writes itself), so alerting is the `filesystem-readonly-probe` DaemonSet (`observability/kube-prometheus-stack/app/filesystem-probe.yaml`) writing `node_filesystem_emergency_readonly`/`node_filesystem_mounted_readonly`/`node_filesystem_emergency_ro_last_check` into the node-exporter textfile dir (hostPath `/var/lib/node_exporter/textfile`, wired via helmrelease `extraHostVolumeMounts`) + the `filesystem-rules` group in the helmrelease `additionalPrometheusRulesMap` (critical → Pushover).
