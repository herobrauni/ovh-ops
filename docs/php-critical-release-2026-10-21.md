# PHP critical security release — idlers + firefly3 temporarily offline (2026-10-21)

**Status: ACTION REQUIRED in the coming days.** Two apps are intentionally disabled in
Git. Nothing else in the cluster runs PHP.

## Why

PHP announced an out-of-band, **critical** security release for 2026-10-21 14:00 UTC
(two vulnerabilities, both CVSS v4.0 **9.2**):

- https://news-web.php.net/php.announce/509

They reserved the right to ship earlier if the details leaked or exploitation was
observed, so the decision on 2026-10-21 07:00 CEST was to stop serving the two PHP
workloads rather than run them unpatched.

## What runs PHP in this cluster

Only these two — verified by pulling every distinct running image's config and
grepping for `PHP_VERSION` / `php-fpm`:

| App        | Image                                                  | PHP at teardown | Exposure                      |
| ---------- | ------------------------------------------------------ | --------------- | ----------------------------- |
| `idlers`   | `ghcr.io/alteredparadox/my-idlers:4.1.0-ap.13`         | 8.5.9           | public, `idlers.brauni.dev`   |
| `firefly3` | `docker.io/fireflyiii/core:latest` (digest `a2b5353…`) | 8.5.10          | public, `firefly3.brauni.dev` |

`idlers` is nginx + php-fpm and is the deliberately split-credential internet-facing
container (see `AGENTS.md`), so it was the priority.

Proxmox VE is **not** affected: its web UI is Perl (`pveproxy`/`pvedaemon` +
`Template`) with an ExtJS frontend, and ships no PHP.

## What was changed

1. `kubernetes/apps/selfhosted/kustomization.yaml` — `./idlers/ks.yaml` and
   `./firefly3/ks.yaml` commented out. Flux prunes the child Kustomizations and
   everything they own (Deployment/StatefulSet, Services, HTTPRoute, ExternalSecret,
   PVCs). DNS records go away with the `dnsendpoint` component.
2. Data protection taken **before** the prune:
    - `VolumeSnapshot/selfhosted/idlers-presecurity-20261021` (`csi-ceph-blockpool`)
    - `VolumeSnapshot/selfhosted/firefly3-presecurity-20261021` (`csi-ceph-blockpool`)
    - Both PVs patched to `persistentVolumeReclaimPolicy: Retain`:
      `pvc-cd3e0b81-d11e-44df-9521-7a3c4061def0` (idlers, MariaDB datadir
      `/var/lib/mysql`) and
      `pvc-eab5b501-1e03-45c1-b418-94f48fc62fb1` (firefly3, `/var/www/html/storage`).

Firefly III's database is **not** on that PVC — it lives in the shared CNPG cluster
`postgres18-rw.dbms.svc.cluster.local`, which stays up and keeps its daily
`postgres18-pgdumpall` schedule. The snapshot covers attachments only.

`idlers` additionally has a kopiur `SnapshotPolicy` (`selfhosted/idlers`, sftp repo,
every 6h) with a successful snapshot from 2026-10-21 04:29 UTC, so its database is
recoverable from kopiur even without the CSI snapshot.

## Re-enable checklist (do all of it, in this order)

1. Confirm patched images exist and read the PHP version out of the image config —
   do not trust tag names:
    ```bash
    # ghcr: token from https://ghcr.io/token?scope=repository:alteredparadox/my-idlers:pull&service=ghcr.io
    curl -s -H "Authorization: Bearer $TOK" \
      -H "Accept: application/vnd.oci.image.manifest.v1+json" \
      https://ghcr.io/v2/alteredparadox/my-idlers/manifests/<tag>   # → config blob → Env PHP_VERSION
    ```
    At teardown the newest tag was `4.1.0-ap.19` (PHP **8.5.11**, built 2026-10-20
    14:33 UTC) — already two patches ahead of what was running. Firefly's
    `latest` digest was the one already pinned (PHP 8.5.10); re-pin only once
    Docker Hub shows a newer digest.
2. Bump `kubernetes/apps/selfhosted/idlers/app/helmrelease.yaml` to the newest
   `my-idlers` tag **and digest**, and `.../firefly3/app/helmrelease.yaml` to the
   newest `fireflyiii/core` digest. Diff the fork's tags first — app changes ride
   along with the PHP base image.
3. Restore each PVC from its snapshot (the PVC is recreated empty by the app
   manifest, so restore first, then uncomment):
    ```bash
    kubectl -n selfhosted get volumesnapshot          # both must be READYTOUSE=true
    ```
    Restore by creating a PVC with `dataSource: {kind: VolumeSnapshot, name: ...}`,
    or use `kubectl kopiur restore` for idlers. Because the old PVs are still
    `Retain`d, delete the Released PVs and their snapshot contents only after the
    new PVCs are bound and the data has been spot-checked.
4. Revert the reclaim policy to `Delete` on any PV you keep, so the next teardown
   does not silently accumulate Released volumes.
5. Uncomment both `resources` entries in
   `kubernetes/apps/selfhosted/kustomization.yaml` and remove the `TEMP(2026-10-21)`
   notes.
6. `task reconcile`, wait for `Kustomization/idlers` and `Kustomization/firefly3` to
   report `Ready`, then verify the PHP version actually in use:
    ```bash
    kubectl -n selfhosted exec deploy/idlers -c app -- php -v
    kubectl -n selfhosted exec deploy/firefly3 -c app -- php -v
    ```
7. Re-check gatus/homepage entries for both hosts come back green, and that
   `idlers.brauni.dev` / `firefly3.brauni.dev` resolve again (external-dns).

## Rollback (re-enable unpatched, e.g. if the release slips)

Uncomment both entries, reconcile, restore PVCs from the snapshots above. That is the
pre-teardown PHP versions — only do it if the advisory was withdrawn.
