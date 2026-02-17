# Talos Configuration Generation

## Run the booter for PXE booting nodes

To pxe boot any nodes, run the following command:

```bash
docker run --rm --network host ghcr.io/siderolabs/booter:v0.3.0 --talos-version=v1.12.2 --schematic-id=ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515
```

This document provides instructions for generating Talos configuration.

## Run the configuration generation task

```bash
task talos:generate-config
```

This command will generate the necessary Talos configuration files based on the current configuration settings.

## Create talsecret

If the talsecret file does not exist, run the following command:

```bash
talhelper gensecret | sops --filename-override talos/talsecret.sops.yaml --encrypt /dev/stdin > talos/talsecret.sops.yaml
```

This command will generate and encrypt the secret configuration file.

## Proxmox Host Network Requirements

The Kubernetes VMs (Talos) run on the `k8s` bridge in PVE's EVPN/VXLAN VRF (`vrf_Zevpn`) while the external Ceph cluster binds to ZeroTier IPs (`172.24.0.0/24`) in the main routing table. Two network configurations are required on **each PVE host** for Ceph to function correctly from inside the VMs.

### Sysctl: Cross-VRF Socket Acceptance

Required for VMs to reach the **local** Ceph monitor/OSD on the same PVE host. Without this, TCP/UDP connections from the `k8s` VRF to Ceph sockets in the main routing table are silently dropped (ICMP works but TCP does not).

```bash
# /etc/sysctl.d/99-ceph-vrf.conf
net.ipv4.tcp_l3mdev_accept=1
net.ipv4.udp_l3mdev_accept=1
```

Apply immediately:

```bash
sudo sysctl -w net.ipv4.tcp_l3mdev_accept=1
sudo sysctl -w net.ipv4.udp_l3mdev_accept=1
```

### IPTables: MASQUERADE on ZeroTier Interface

Required for VMs to reach **remote** Ceph monitors/OSDs on other PVE hosts. Without this, the remote host receives packets with a source IP from the `k8s` subnet (`10.10.8.0/24`) which it cannot route back to (those routes only exist in the VRF, not in the main table).

```bash
# In /etc/network/interfaces (on the vmbr0 stanza)
post-up   iptables -t nat -A POSTROUTING -o ztdiyrsa75 -j MASQUERADE
post-down iptables -t nat -D POSTROUTING -o ztdiyrsa75 -j MASQUERADE
```

### Summary

| VM → Ceph traffic path | Required configuration |
|---|---|
| Local (same PVE host) | `tcp_l3mdev_accept=1` / `udp_l3mdev_accept=1` sysctl |
| Remote (different PVE host) | `MASQUERADE -o ztdiyrsa75` iptables rule |

## External Ceph Monitoring Configuration

When using an external Ceph cluster with Rook, additional Ceph manager configuration is required to expose detailed metrics for Grafana dashboards (e.g., Write Throughput, Read Throughput, OSD Latency).

### Enable Detailed OSD Metrics

Run the following commands on your external Ceph cluster to enable detailed OSD operation metrics:

```bash
# Enable RBD stats for all pools
sudo ceph config set mgr mgr/prometheus/rbd_stats_pools "*"

# Enable perf counters for detailed metrics
sudo ceph config set mgr mgr/prometheus/exclude_perf_counters false
```

### What This Enables

These configuration changes enable the following metrics that are required by the Ceph Grafana dashboards:

- `ceph_osd_op_w_in_bytes` - Write bytes per OSD (for Write Throughput)
- `ceph_osd_op_r_out_bytes` - Read bytes per OSD (for Read Throughput)
- `ceph_osd_op_w_latency_sum/count` - Write latency metrics
- `ceph_osd_op_r_latency_sum/count` - Read latency metrics

Without these settings, the Grafana dashboards will show missing or empty data for throughput and latency metrics.

### Verification

After applying the configuration, you can verify the metrics are being exposed by checking the Ceph manager Prometheus endpoint:

```bash
# Check if OSD operation metrics are available
curl http://<ceph-mgr-ip>:9283/metrics | grep "ceph_osd_op_w_in_bytes"
```

The metrics should automatically appear in Prometheus and Grafana after the next scrape interval (default: 10s).