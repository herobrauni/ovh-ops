# Staging workloads (migration phases 2–4)

Per-node "staging cells" on the 270 GiB `staging` user volumes, consumed via
the `staging-hostpath` StorageClass (OpenEBS localpv on `/var/mnt/staging`):

| Shard | Node | Workload | PVC | NodePort |
|---|---|---|---|---|
| s1 | mini1 | MinIO | 125 GiB | 30901 |
| s2 | mini2 | MinIO | 125 GiB | 30902 |
| s3 | mini3 | MinIO | 125 GiB | 30903 |
| s1 | mini1 | restic rest-server | 125 GiB | 30911 |
| s2 | mini2 | restic rest-server | 125 GiB | 30912 |
| s3 | mini3 | restic rest-server | 125 GiB | 30913 |

All endpoints are reachable from the OVH cluster through the existing
OPNsense↔OVH site WireGuard tunnels (`10.100.15.0/24` is already routed) —
no inbound port forwarding at home required.

## What lands where (phase 2 sizing, ~810 GiB single-copy capacity)

- **restic repositories** (VolSync `ReplicationSource` on OVH →
  `rest:http://10.100.15.6X:3091X/<repo>/`): Kubernetes PVCs (~216 GiB
  logical, ~250 GiB across repos after dedup/compression) split by
  namespace across the three rest-servers.
- **S3 mirror** (`rclone sync` of the Proxmox RGW buckets, 342 GiB):
  buckets are spread by size across the three MinIO shards (~114 GiB each).

The OVH cluster keeps the only production copy until cutover; single-copy
staging is accepted for that window.

## Before real data lands

- Create the shared MinIO root credential manually (staging only — kept out of Git):
  `kubectl -n staging create secret generic minio-staging --from-literal=rootUser=… --from-literal=rootPassword=…`
- Add htpasswd auth to the rest-servers (replace `--no-auth`).
- Verify NodePort reachability from an OVH node: `curl 10.100.15.61:30901/minio/health/live`.
