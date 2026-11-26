# Proxmox VE hosts (hypervisors) — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when touching metrics/health data
that originates on the three PVE hypervisors rather than in the Kubernetes cluster.

## Hosts and access

- `ovhsbg1` 54.38.92.92, `ovhsbg2` 54.38.94.158, `ovhsbg3` 54.38.94.150 (PVE 9.2.x, kernel 7.0.x-pve). SSH as `brauni` (`~/.ssh/config` host aliases), root work via `sudo`.
- The Talos nodes (`c-ovhsbg1`, `w-ovhsbg2`, …) are **VMs on these hosts**, one per host on the per-host `k8s` bridge `10.10.8.0/24` (`.1` = the PVE host). Ceph (OSDs/mons, Rook external mode) also runs here — see `docs/agents/ceph.md`.

## Exporters on the hosts are OUT-OF-BAND (not GitOps)

Nothing in `kubernetes/` installs these; they were set up by hand and are only _scraped_ from Git:

| Exporter                          | Port | Install                                                                                                                   | Notes                                                                                                                                   |
| --------------------------------- | ---- | ------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `prometheus-node-exporter`        | 9100 | Debian package 1.9.0, `User=prometheus`, args in `/etc/default/prometheus-node-exporter`                                  | `--collector.smartctl` is NOT used (that yields `node_smartctl_*`, not the dashboard's `smartctl_*`)                                    |
| `smartctl_exporter`               | 9633 | `/usr/local/bin/smartctl_exporter` + `/etc/systemd/system/smartctl-exporter.service` (root; scanning needs device access) | `smartmontools 7.5-pve2`; the internal scanner only finds `/dev/nvme0`, `/dev/nvme1`                                                    |
| `zfs_exporter` (pdf/zfs_exporter) | 9134 | `/usr/local/bin/zfs_exporter` + `zfs-exporter.service`                                                                    | pool collector default props; `zfs_pool_health` codes are 0 ONLINE, 1 DEGRADED, 2 FAULTED, 3 OFFLINE, 4 UNAVAIL, 5 REMOVED, 6 SUSPENDED |

Changing/upgrading an exporter means SSH+systemd work per host; there is no Ansible/playbook repo
for them, so record any version bump here.

## Scraping (the part that IS GitOps)

All PVE jobs live in `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml` →
`additionalScrapeConfigs`, share the `node`/`role=proxmox`/`site=riki` labels and relabel
`instance` to the host name: `proxmox-node-exporter` (:9100), `proxmox-zfs` (:9134),
`proxmox-smartctl` (:9633) and `proxmox-pve` (`/pve` on the in-cluster exporter).

- The host jobs target the three **public** IPs. That works from inside the cluster because the
  scrape leaves a VM on the bridge and hits the host's own public address, so the source is
  `10.10.8.x` — it is never internet-routed.
- `/etc/pve/firewall/cluster.fw` (also out-of-band) sets `policy_in: DROP` and opens `9100`,
  `9134`, `9633`, `8006` and ICMP **only** from `10.10.8.0/24`. A new exporter port needs an edit
  there on a PVE host, not just a scrape config.
- `prometheus-pve-exporter` (app `observability/proxmox-exporter`) is **multi-target**: `/metrics`
  serves only its own process metrics, PVE data is behind `/pve?target=<api-host>`, and the target
  defaults to `localhost` (so a plain `/metrics` ServiceMonitor yields nothing — that was the state
  until the pve/zfs scrape jobs were added). The scrape config passes `params.target` and points
  `__address__` at the exporter service, so `instance` is the PVE host. Only ONE target is
  scraped: every node's API returns the same cluster-wide data, and three targets would duplicate
  every cluster/storage series per node.

## pve-exporter: auth and TLS traps

- `PVE_HOST` is **dead config**: `config_from_env()` only reads `PVE_USER`, `PVE_PASSWORD`,
  `PVE_TOKEN_NAME`, `PVE_TOKEN_VALUE`, `PVE_VERIFY_SSL`, `PVE_MODULE`. The API host comes from the
  scrape URL only — the `/proxmox-exporter/PVE_HOST` key is still in Infisical but no longer mapped
  into the pod.
- Token privileges are the **intersection of the token's ACLs and its user's ACLs**. Granting
  `PVEAuditor` to the token alone does nothing (`pveum user permissions 'monitoring@pam!monitoring'`
  prints an empty tree); the user needs the role too:
  `pveum acl modify / --users monitoring@pam --roles PVEAuditor`. Symptom before the fix:
  `/nodes` and `/cluster/resources` worked (200) but `/cluster/status` and `/cluster/backup`
  returned `403 Permission check failed (/, Sys.Audit)`, so the whole `/pve` scrape 500s.
- TLS: node certs are signed by the cluster CA (`/etc/pve/pve-root-ca.pem`, identical on all three,
  CN `Proxmox Virtual Environment`) and their SANs include each host's public IP, so IP targets
  verify cleanly. `PVE_VERIFY_SSL` stays `true`; the CA is committed as
  `proxmox-exporter/app/pve-root-ca.pem` (public cert, no key) via `configMapGenerator` and wired in
  as `REQUESTS_CA_BUNDLE`. **If the PVE CA is ever regenerated, refresh that file** — the exporter
  otherwise 500s and `ProxmoxExporterDown` fires.

## SMART data

- Hosts are 2× NVMe each (`INTEL SSDPF2KX019T1O`, the Ceph OSD devices); there are **no SATA/SAS
  spinners**, so ATA-only series (`smartctl_device_attribute`, i.e. no `Wear_Leveling_Count`
  attribute) are absent — the attribute-based target of 22604's "Wear Leveling Over Time" panel is
  legitimately empty (the `smartctl_device_percentage_used` target is not). NVMe _does_ expose
  `smartctl_device_bytes_written` / `smartctl_device_bytes_read` (log page 0x02 "Data Units
  Written"; currently 160–425 TB per drive) — an earlier version of this note wrongly called them
  ATA-only, which is why the dashboard's "Total Data Written on SSDs" table looked empty before
  the scrape job existed.
- **`device` labels are not stable.** On 2026-11-26 ~07:39 the exporter swapped `nvme0` ↔ `nvme1`
  on `ovhsbg1` and `ovhsbg2` (smartctl's scan/`/dev/nvmeX` numbering reordered; serials stayed put).
  Any panel or rule keyed on `device` sees a bogus counter "reset" (that day: 166.9 TB → 162.7 TB).
  Key on `serial_number` (joined via `smartctl_device`) instead, and aggregate to
  `by (instance, serial_number)` **before** `deriv`/`rate` so the discontinuity is not a spike.
- Dashboards: `GrafanaDashboard/smartctl-exporter` is a **local fork** of grafana.com 22604 rev 4
  (`proxmox-exporter/app/resources/smartctl.json`, wired via `configMapRef`) because two panels were
  added: "Data Written (lifetime)" and "Write Rate (per day, 6h avg)" — both keyed on
  `serial_number`. Upstream updates to 22604 no longer arrive automatically; re-fork if wanted.
  `GrafanaDashboard/proxmox-pve-exporter` still pulls grafana.com 10347 rev 5; its `instance`
  variable is the PVE source host, so every panel resolves through the single `proxmox-pve` target.
  Baseline write rate with an idle cluster is ~330–450 GB/day/drive (ovhsbg3 runs higher, ~780),
  which at 1.92 TB/drive and 1–2% wear used is the number to watch for endurance burn.
- Alert rules (`proxmox-exporter/app/prometheusrule.yaml`) are written against the real series:
  `smartctl_device_smart_status` (1 = PASSED — do **not** reintroduce
  `smartctl_device_smart_healthy`, the exporter never exposes it), `zfs_pool_health`,
  `pve_cluster_info{quorate}`, `pve_up{id=~"node/.+"}`, `pve_disk_*`.
- `pve_disk_*{id="storage/<node>/<storage>"}` repeats cluster-wide (shared) storages once per node,
  so the storage-free rules collapse the node prefix out of `id` with `label_replace` +
  `min by (storage)`.
- PVE reports node memory including the reclaimable ZFS ARC (hosts idle at ~0.85), and 14d of
  `node_memory_MemAvailable` never crossed 0.90 — hence the loose `> 0.95` memory threshold.
- Measurable but deliberately not alerted: `pve_not_backed_up_total` (currently 8 guests without a
  backup job) and `pve_subscription_status` (all host nodes report `notfound`, no subscriptions).
