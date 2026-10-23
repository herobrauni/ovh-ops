# Backups: kopiur, VolSync removal, CNPG — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when adding/migrating backup
policies, restoring data, or touching the VolSync leftovers.

## Current state

- **The VolSync → kopiur migration is complete**: 30 `SnapshotPolicy`s (28 component-based apps + the two hand-written `dbms` pgdumpall dumps), **0 `ReplicationSource`s** and **0 `*-volsync` ExternalSecrets** cluster-wide. `kopiur-system/kopiur` runs the home-operations kopiur operator; `ClusterRepository/sftp` **adopts** the same kopia SFTP repository the perfectra1n volsync fork wrote to (no `create` block — it can never format a fresh repo over the history).
- The VolSync operator is **deliberately still deployed** (rollback path: reverting an app's `ks.yaml` to `components/volsync` lets the fork's `ReplicationSource` re-adopt the same pinned kopia series; neither direction destroys anything — the orphan `<app>-dst` `ReplicationDestination`s make the reverse likewise inert).

## Adding an app to kopiur (`kubernetes/components/kopiur`)

Order per app: `components/kopiur` + `dependsOn volsync` (fork era) or straight in (greenfield) → `kopiur-repository` + `KOPIUR_*` substitutes. Hard requirements:

1. The chart flag `features.credentialProjection.enabled: true` MUST be set on the operator — its `secrets` create/patch/delete RBAC is gated on it (necessarily unscoped; `create` cannot be resourceName-scoped), and without it every mover Job 403s with a `MissingDependency` naming the flag.
2. Adopting the fork's repo requires pinning `sources[0].sourcePathOverride: /data` on every SnapshotPolicy — kopiur's default source path is `/pvc/<name>`, so without the pin the history silently forks and `fromPolicy` restores come up empty.
3. `identityDefaults` (`hostnameExpr: namespace`, `usernameExpr: policyName`) reproduce the fork's `<app>@<namespace>` identity (same as kopiur's bare defaults).
4. The SFTP host/port/username stay out of Git via Flux `postBuild.substituteFrom` on `kopiur-sftp-config` — that ExternalSecret MUST live in the operator Kustomization, NOT in the Kustomization whose postBuild consumes it (Flux resolves substitution at build time → same-Kustomization producer deadlocks `BuildFailed` forever).
5. Credentials (`KOPIA_SFTP_KEY_DATA`/`KOPIA_SFTP_KNOWN_HOSTS`/`KOPIA_PASSWORD`) live in `kopiur-repository` and are **projected** into consumer namespaces — the kopiur component needs NO per-app ExternalSecret, unlike the volsync one.
6. Migrated apps set `KOPIUR_ON_MISSING_SNAPSHOT: Fail` (fail-closed DR); greenfield keeps the `Continue` deploy-or-restore default.
7. Substitute names (`VOLSYNC_*` → `KOPIUR_*`): `KOPIUR_CAPACITY`, `KOPIUR_SNAPSHOTCLASS`, `KOPIUR_STORAGECLASS`, `KOPIUR_ACCESSMODES`, `KOPIUR_CLAIM`, `KOPIUR_CACHE_CAPACITY` (default `32Gi`), `KOPIUR_MOVER_UID/GID`. `VOLSYNC_SNAP_ACCESSMODES`/`VOLSYNC_PUID` have no equivalent (kopiur derives staging from the source PVC).

## Retention (read this before changing it)

- `SnapshotPolicy.spec.retention` is the **only** thing that prunes successful snapshots, and its GFS buckets are a **union in which an absent bucket keeps nothing** (`None` ≡ `0`, verified in upstream `crates/api/src/retention.rs`; never read "unset" as "unlimited").
- `kubernetes/components/kopiur` declares the window explicitly — `keepHourly: 12`, `keepDaily: 14`, `keepWeekly: 8`, `keepMonthly: 6`, `keepAnnual: 1` (≈3 days at 6-hourly granularity, then daily to 2 weeks, weekly to 2 months, monthly to ~6 months), overridable per app through `KOPIUR_KEEP_HOURLY/DAILY/WEEKLY/MONTHLY/ANNUAL/LATEST`.
- This matters because the migration's first cut inherited volsync's 24h/7d window and dutifully began retiring the fork-era anchors, one `SnapshotDeleteBatch` per scheduled run (~168 points older than 7 days were queued before the window was widened). Already-pruned points are hard-deleted and unrecoverable. Individual snapshots can be protected from GFS entirely with `Snapshot.spec.pin` / `kopiur snapshot now --pin`.
- `adoption.totalAdopted` therefore exceeds the repository's identity count.

## Mover privileges

- The mover runs with `SnapshotPolicy.spec.mover.podSecurityContext` and **silently skips paths it cannot read** — an unprivileged (1000:1000) mover snapshotted a root-owned volume successfully while dropping its `lost+found/` entry, exactly the kind of invisible completeness gap a backup must not have. Run the mover at the privilege that can read the source.
- When that means root, the namespace needs the explicit opt-in `kopiur.home-operations.com/privileged-movers: "true"` (mirrors volsync's; gated because a tenant could otherwise reuse the minted `kopiur-mover` ServiceAccount). Without it every `Snapshot` parks at `MoverPermitted=False/PrivilegedMoverNotPermitted` and **backups silently stop** (the condition message carries the fix). `ns dbms` sets it because its `pgdumpall` CronJobs write as 0:0; the 28 app sources are all 1000:1000 and need no opt-in.

## Repository size / maintenance

- The repository sits just past kopiur's compiled-in snapshot-materialization cap: every discovery pass logs `catalog larger than the materialization cap; not all snapshots were materialized repo=sftp snapshot_count=1007`, and the limit is not exposed as a chart value, arg or env. Harmless in practice — the capped-out part is the _unmatched_ history owned by no policy, and unmaterialized snapshots are never pruned (GFS pruning is policy-scoped) — but `kubectl get snapshot` no longer lists the whole repository; use an independent kopia client for repository truth (as with `adoption.totalAdopted`).
- The `Maintenance` CR is healthy and self-managing (quick `0 * * * *` jitter 10m, full `0 3 * * *` jitter 1h, both Europe/Paris): `status.full.lastRunAt` / `status.quick.lastRunAt` stamp each pass, `lastContentReclaimedBytes` shows what it reclaimed (0 so far). Completed mover/delete Jobs are TTL-reaped, so an empty `kubectl -n kopiur-system get jobs` is not evidence that nothing ran — use the `Snapshot` CRs, `SnapshotPolicy.status.retention` stamps, or the repository itself.

## dbms pgdumpall dumps

- The last two volsync sources, the `dbms` `pgdumpall` dumps (`kubernetes/apps/dbms/cloudnative-pg/cluster/pgdumpall.yaml`), are kopiur now. Their `SnapshotPolicy`s are hand-written (the dumps are plain PVC+CronJob stacks) and keep retention explicit — `keepLatest 10 / keepWeekly 6 / keepMonthly 6 / keepAnnual 2`, a field-for-field translation of the fork's `retain` — with the mover left at `0:0`/`fsGroup 1000`, matching the CronJob that writes the dumps.
- They deliberately carry **no `Restore` CR**: a passive-populator Restore sits at `Ready=False/AwaitingPvcDataSourceRef` until a claim references it, and that Kustomization runs with `wait: true`, so the CR would stall the whole `dbms` cluster Kustomization. Create a `Restore` on demand when restoring a dump (then claim it with a `dataSourceRef` PVC, as the app components do).

## Restoring app data

- Restore through the kopiur populator rather than a Git-hand-written PVC: `components/kopiur` already emits the `${APP}` claim with `dataSourceRef` → `Restore`. `Restore` failure leaves the pod `Pending` on an unbound claim (`KOPIUR_ON_MISSING_SNAPSHOT: Fail`) instead of booting empty.
- Confirm the identity and newest snapshot before enabling: `kubectl -n volsync-system exec deploy/kopia -c app -- kopia snapshot list --all --config-file /config/repository.config`.

## VolSync removal checklist (when the rollback safety net is no longer wanted)

1. `kubernetes/apps/volsync-system/volsync/` (Flux Kustomization, HelmRelease, OCIRepository, Grafana dashboard, PrometheusRule) **and** its `mutatingadmissionpolicy.yaml` — `volsync-mover-jitter` and `volsync-pgdump-rw-rootfs` are `MutatingAdmissionPolicy` objects, so `kubectl get validatingadmissionpolicy` will not show them — plus its entry in `kubernetes/apps/volsync-system/kustomization.yaml`.
2. `kubernetes/components/volsync/` (no consumers left as of 2026-10-20) — together with `kubernetes/components/cnpg/pgdump.yaml`, an **unreferenced dead template** (the `components/cnpg` kustomization only lists `externalsecret.yaml`) that still emits a volsync `ReplicationSource` and `${APP}-pgdump-volsync` ExternalSecret; delete or port it rather than leaving it to be resurrected.
3. The `healthChecks` entries for `volsync.backube/v1alpha1`/`ReplicationSource` in `kubernetes/apps/system-upgrade/tuppr/upgrades/{kubernetes,talos}upgrade.yaml` (dead once the CRD is gone).
4. Last and optional: the 56 runtime-created orphan `ReplicationDestination`s (not in Git; media has 34, including `*-pg-backups-dst` and RDs for apps that no longer exist). Deleting the CRDs takes them with it — bound PVCs keep their immutable `dataSourceRef`, so nothing breaks.

**Keep**: `kubernetes/apps/volsync-system/kopia/` (the KopiaUI repository browser at `kopia.riki.boo`), hence the `volsync-system` namespace itself, and the authentik/tinyauth `ReferenceGrant`s naming `volsync-system` (they point at the kopia UI's SecurityPolicy/HTTPRoute). The Infisical `/volsync-template/*` and `/kopia_known_hosts/*` values must stay (kopiur-repository consumes them).

## CNPG backups

- CNPG cluster backups in `kubernetes/apps/dbms/cloudnative-pg/cluster` use `ScheduledBackup.spec.method: barmanObjectStore` with the `cnpg-backups` ObjectBucketClaim/secret; do not reintroduce VolumeSnapshot or VolSync resources just to enable routine backups.
- When bootstrapping a replacement CNPG cluster from an object-store backup while keeping backup archiving enabled, do not point the new cluster at the same Barman archive path/server lineage as the source backup. Use a fresh backup destination (for example `.../v2/`) or another unique server name, otherwise recovery can fail with `Expected empty archive` during the WAL archive safety check.
