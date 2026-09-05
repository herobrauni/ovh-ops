# Talos Configuration

Machine configs are assembled by [topf](https://postfinance.github.io/topf/)
from `topf.yaml` plus the strategic merge patches in this directory.

<https://www.talos.dev/latest/talos-guides/configuration/patching/>

## Patch Directories

Patches merge in this order, alphabetically within each directory, with later
patches taking precedence:

- `all/`: applied to every node
- `control-plane/`: applied to control-plane nodes
- `worker/`: applied to worker nodes
- `node/${hostname}/`: applied to the node with the specified name

Files ending in `.yaml.tpl` are Go-templated per node; see the
[topf configuration model](https://postfinance.github.io/topf/main/configuration-model/)
for the available template variables.

The cluster uses the Talos v1.14 multi-document config format (typed
`Kube*Config` / `SysctlConfig` / `ResolverConfig` / `CRICustomizationConfig` /
`UnattendedInstallConfig` documents alongside the remaining v1alpha1 fields).
The 1.13-format config cannot be applied to 1.13 nodes — `topf apply` only
works once the nodes run the `talosVersion` pinned in `topf.yaml`, so upgrade
Talos first, then apply the migrated config.
