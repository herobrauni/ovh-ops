# Proxmox VE hosts (hypervisors) — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when touching metrics/health data
that originates on the three PVE hypervisors rather than in the Kubernetes cluster.

## Hosts and access

- `ovhsbg1` 54.38.92.92, `ovhsbg2` 54.38.94.158, `ovhsbg3` 54.38.94.150 (PVE 9.x, kernel 7.0.x-pve). SSH as `brauni` (`~/.ssh/config` host aliases), root work via `sudo`.
- The Talos nodes (`c-ovhsbg1`, `w-ovhsbg2`, …) are **VMs on these hosts**, one per host on the per-host `k8s` bridge `10.10.8.0/24` (`.1` = the PVE host). Ceph (OSDs/mons, Rook external mode) also runs here — see `docs/agents/ceph.md`.

## Exporters on the hosts are OUT-OF-BAND (not GitOps)

Nothing in `kubernetes/` installs these; they were set up by hand and are only _scraped_ from Git:

| Exporter                   | Port | Install                                                                                                                   | Notes                                                                                                     |
| -------------------------- | ---- | ------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `prometheus-node-exporter` | 9100 | Debian package 1.9.0, `User=prometheus`, args in `/etc/default/prometheus-node-exporter`                                  | `--collector.smartctl` is NOT used (that would yield `node_smartctl_*`, not the dashboard's `smartctl_*`) |
| `smartctl_exporter`        | 9633 | `/usr/local/bin/smartctl_exporter` + `/etc/systemd/system/smartctl-exporter.service` (root, scanning needs device access) | `smartmontools 7.5-pve2`; internal scanner only finds `/dev/nvme0`, `/dev/nvme1`                          |
| `zfs_exporter`             | 9134 | `/usr/local/bin/zfs_exporter` + `zfs-exporter.service`                                                                    | exposes only `zfs_pool_free_bytes`/`zfs_pool_size_bytes` for pool `data` — **no** `zfs_pool_state`        |

Changing/upgrading an exporter means SSH+systemd work per host; there is no Ansible/playbook repo
for them, so record any version bump here.

## Scraping (the part that IS GitOps)

- `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml` → `additionalScrapeConfigs`:
  `proxmox-node-exporter` (:9100) and `proxmox-smartctl` (:9633), both with `static_configs` of the
  three **public** IPs, labels `node`/`role=proxmox`/`site=riki`, and `instance` relabeled to the
  host name.
- Public IPs work from inside the cluster because the scrape leaves a VM on the bridge and hits the
  host's own public address, so the source is `10.10.8.x` (see the firewall rule below) — it is not
  internet-routed.
- `/etc/pve/firewall/cluster.fw` (also out-of-band) sets `policy_in: DROP` and opens `9100`, `9134`,
  `9633`, `8006` and ICMP **only** from `10.10.8.0/24`. Adding a new exporter port requires editing
  that file on a PVE host, not just the scrape config.
- PVE API exporter (`prompve/prometheus-pve-exporter`, app `observability/proxmox-exporter`) is
  scraped on its own `/metrics` with no `target=` parameter, so it currently only serves its own
  process metrics — no `pve_*` data series. The `proxmox_*`/`zfs_pool_state` rules in
  `proxmox-exporter/app/prometheusrule.yaml` therefore never fire (metric names that no exporter
  produces); known gap, not a regression.

## SMART data

- Hosts are 2× NVMe each (`INTEL SSDPF2KX019T1O`, i.e. the Ceph OSD devices); there are **no SATA/SAS
  spinners**, so ATA-only series (`smartctl_device_attribute`, `smartctl_device_bytes_written`,
  `smartctl_device_power_on_seconds`) are absent — the "Total Data Written on SSDs" and "Wear
  Leveling Over Time" panels of dashboard 22604 are legitimately empty. Use
  `smartctl_device_percentage_used` / `smartctl_device_available_spare` / `smartctl_device_bytes_written`
  instead.
- Dashboard: `GrafanaDashboard/smartctl-exporter` (grafana.com 22604 rev 4, latest) lives in
  `proxmox-exporter/app/grafanadashboard.yaml`; its `instance` variable resolves to `ovhsbg1..3`
  because of the relabel above.
- Alerts (`proxmox-exporter/app/prometheusrule.yaml`) use the exporter's real series:
  `smartctl_device_smart_status == 0` (1 = PASSED) — do **not** reintroduce
  `smartctl_device_smart_healthy`, which the exporter never exposes.
- SMART scrape is `60s` (smartctl runs are cached in-process, no need for 30s); each host reports
  both NVMe devices, all currently PASSED, 0 critical warnings, 0 media errors.
