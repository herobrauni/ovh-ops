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