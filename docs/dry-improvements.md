# DRY Improvement Proposals & Architecture Guide

Written 2026-10-13 as an analysis of repetition across the repository with concrete recommendations for DRY (Don't Repeat Yourself) improvements across Flux, Gateway API, Kustomize components, and HelmReleases.

---

## 1. Executive Summary & Impact Matrix

| Area                                  | Current Duplication                                                 | Proposed Solution                                                      | Quantified Impact                                                         | Risk & Effort   |
| :------------------------------------ | :------------------------------------------------------------------ | :--------------------------------------------------------------------- | :------------------------------------------------------------------------ | :-------------- |
| **`app-template` OCIRepository**      | 62 identical `ocirepository.yaml` files                             | Reusable `components/app-template` included at namespace layer         | **61 files deleted** (~1,000 LOC); Renovate updates 1 component file      | Low / Low       |
| **HelmRelease `driftDetection`**      | Repeated across 97 `helmrelease.yaml` files                         | Inject via `patches` in `flux-system/cluster-apps`                     | **97 files simplified**; guaranteed cluster-wide coverage by design       | Low / Low       |
| **Authentik Outpost HTTPRoutes**      | 19 identical `httproute-outpost.yaml` files                         | Shared multi-host HTTPRoutes in ns `authentik` (`outpost-routes.yaml`) | **19 files deleted** (~600 LOC); explicit hostnames per domain Gateway    | Low / Medium    |
| **DNSEndpoint Manifests**             | 61 `dnsendpoints.yaml` files                                        | Reusable `components/dnsendpoint` component (single-endpoint apps)     | **39 files deleted** (~660 LOC); 22 non-standard/multi-endpoint kept      | Low / Low       |
| **Media Rclone Sidecar & Mounts**     | ~100 LOC duplicated across 17 media HelmReleases                    | Reusable `media/components/rclone-zurg` component                      | **~1,400 LOC eliminated**; single place to update rclone flags & cache    | Medium / Medium |
| **4K Media Workloads**                | `sonarr4k`, `radarr4k`, `bazarr4k` duplicate 1080p counterparts 1:1 | Kustomize overlays or Flux `postBuild` parameterization                | **21 files eliminated**; guaranteed parity between 1080p and 4K instances | Medium / Medium |
| **Shared Servarr Secrets**            | 10 independent ExternalSecrets querying `/servarr/API_KEY`          | Single `ExternalSecret/servarr-secret` in `media` namespace            | **5 ExternalSecrets eliminated**; 5 kept due to ESO template requirements | Low / Low       |
| **Authentik ExtAuth SecurityPolicy**  | 21 identical 35-line `extAuth` blocks                               | Reusable `components/authentik` extAuth component                      | **10 SecurityPolicies eliminated**; 11 non-standard/custom kept           | Low / Medium    |
| **Legacy VolSync & TinyAuth Cleanup** | In-flight migrations leaving dead manifests & duplicate controllers | Decommission unused TinyAuth and complete VolSync -> Kopiur transition | Drops 2 controllers, redundant RBAC, and dead configs                     | Low / Medium    |

---

## 2. Detailed Improvement Proposals

### 2.1 Centralize `app-template` OCIRepository

#### Problem

Every application leveraging `app-template` maintains its own `ocirepository.yaml` in its `app/` folder (62 files in total). All 62 point to `oci://ghcr.io/bjw-s-labs/helm/app-template` with identical tags and SHA256 digests.

When Renovate bumps `app-template`, it commits a massive diff touching 62 files at once (e.g. commit `14a0b814`), creating git churn and frequent merge conflicts.

#### Implemented Solution

Create a reusable component in `kubernetes/components/app-template/ocirepository.yaml` and include it in each namespace-level `kustomization.yaml` (7 namespaces: `ai`, `media`, `network`, `niks3`, `observability`, `selfhosted`, `volsync-system`):

1. Define the shared `OCIRepository` resource:
    ```yaml
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: OCIRepository
    metadata:
        name: app-template
    spec:
        interval: 15m
        layerSelector:
            mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
            operation: copy
        ref:
            tag: 5.3.0
            digest: sha256:0e13b145656490310ada364d8eb708e5f4f6384c7deb60d3f5f0fa56950ff63a
        url: oci://ghcr.io/bjw-s-labs/helm/app-template
    ```
2. In all 62 `helmrelease.yaml` files, update `spec.chartRef`:
    ```yaml
    spec:
        chartRef:
            kind: OCIRepository
            name: app-template
    ```
3. Remove `./ocirepository.yaml` from all app-level `kustomization.yaml` files (61 deleted, 1 moved to component).
4. Renovate now tracks and updates `app-template` in a single component file across the 7 consumer namespaces while preserving strict namespace encapsulation.

---

### 2.2 Global HelmRelease Defaults in `cluster-apps`

#### Problem

97 `helmrelease.yaml` manifests duplicate:

```yaml
spec:
    driftDetection:
        mode: enabled
```

A script (`util/check_drift_detection.sh`) exists solely to grep for this configuration to catch omitted entries.

At the same time, `kubernetes/flux/cluster/ks.yaml` already patches `install`, `rollback`, and `upgrade` remediation policies into all child HelmReleases.

#### Proposal

Add `driftDetection` directly to the `cluster-apps` Flux Kustomization patch in `kubernetes/flux/cluster/ks.yaml`:

```yaml
patches:
    - patch: |-
          apiVersion: helm.toolkit.fluxcd.io/v2
          kind: HelmRelease
          metadata:
            name: _
          spec:
            driftDetection:
              mode: enabled
            install:
              crds: CreateReplace
              strategy:
                name: RetryOnFailure
            rollback:
              cleanupOnFail: true
            upgrade:
              cleanupOnFail: true
              crds: CreateReplace
              strategy:
                name: RemediateOnFailure
              remediation:
                remediateLastFailure: true
                retries: 2
      target:
          group: helm.toolkit.fluxcd.io
          kind: HelmRelease
```

- Eliminates `driftDetection` boilerplate across 97 manifests.
- Enforces drift detection cluster-wide by default, removing the need for manual grep audits.

---

### 2.3 Shared Authentik Outpost HTTPRoutes

#### Problem

Every app protected by Authentik forward-auth currently requires a dedicated `httproute-outpost.yaml` (19 files) to route `/outpost.goauthentik.io` callbacks to `authentik-server:80` without extAuth:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
    name: sonarr-480p-com-outpost
    annotations:
        gatus.home-operations.com/enabled: "false"
spec:
    hostnames: ["sonarr.480p.com"]
    parentRefs:
        - name: envoy-480p-com-public
          namespace: network
          sectionName: https
    rules:
        - matches:
              - path:
                    type: PathPrefix
                    value: /outpost.goauthentik.io
          backendRefs:
              - name: authentik-server
                namespace: authentik
                port: 80
```

#### Why Wildcard Hostnames Failed

An initial attempt used wildcard hostnames (`*.480p.com`, `*.brauni.dev`, `*.riki.boo`). However, normative Gateway API v1.2.1 precedence rules (`apis/v1/httproute_types.go`) mandate that non-wildcard exact hostnames take precedence over wildcard hostnames _before_ path prefix matching is evaluated. Because every protected app has an exact-hostname route with a catch-all `/` path, `sonarr.480p.com` with path `/` shadowed `*.480p.com` on `/outpost.goauthentik.io`. The app container received the callback and responded `404`, breaking authentication.

#### Implemented Solution

Consolidate into shared HTTPRoutes in `kubernetes/apps/authentik/authentik/app/outpost-routes.yaml` (one per public Gateway: `480p.com`, `brauni.dev`, `riki.boo`) using **explicit hostname lists**:

1. Deploy shared HTTPRoutes with explicit `spec.hostnames`:
    ```yaml
    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
        name: authentik-outpost-480p-com
        namespace: authentik
        annotations:
            gatus.home-operations.com/enabled: "false"
    spec:
        parentRefs:
            - name: envoy-480p-com-public
              namespace: network
              sectionName: https
        hostnames:
            - sonarr.480p.com
            - radarr.480p.com
            # ... all protected hostnames for this domain
        rules:
            - matches:
                  - path:
                        type: PathPrefix
                        value: /outpost.goauthentik.io
              backendRefs:
                  - name: authentik-server
                    port: 80
    ```
2. Delete all 19 app-level `httproute-outpost.yaml` files.
3. Prune the 6 dead cross-namespace `HTTPRoute` entries from `referencegrant.yaml` (outpost routes now run in ns `authentik` and access `authentik-server` locally).
4. Onboarding a new app simply requires appending its hostname to `outpost-routes.yaml`.

---

### 2.4 Componentize DNSEndpoint (`components/dnsendpoint`)

#### Problem

61 apps duplicate 17-line `dnsendpoints.yaml` manifests pointing a CNAME at `public.<domain>`.

Following the split-horizon DNS outage noted in `AGENTS.md` (where `external-dns` dropped set-based annotation filters), external-dns requires both `labels.dns.scope: all` and `annotations.dns.scope: all`. Duplicating this manually across 61 files risks inconsistencies when adding new apps.

#### Implemented Solution

Create a reusable Kustomize component `kubernetes/components/dnsendpoint/`:

```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
    name: ${APP}
    labels:
        # Split-horizon scoping. The label is load-bearing: external-dns v0.22+ is configured with
        # --label-filter=dns.scope in (...), NOT --annotation-filter (which silently matches nothing).
        # The annotation is kept for backwards compatibility/visibility — do not delete either one.
        dns.scope: ${DNS_SCOPE:=all}
    annotations:
        dns.scope: ${DNS_SCOPE:=all}
spec:
    endpoints:
        - dnsName: ${APP}.${DOMAIN}
          recordType: CNAME
          targets:
              - public.${DOMAIN}
```

In each app's `ks.yaml`:

```yaml
spec:
    components:
        - ../../../../components/dnsendpoint
    postBuild:
        substitute:
            APP: *app
            DOMAIN: 480p.com
```

- Consolidates 39 single-endpoint files (38 deleted, 1 moved to component).
- Deliberately preserves 22 non-standard or multi-endpoint manifests (e.g. `homepage`, `echo`, `technitium-dns`, `jellyfin`, `comet`, etc.) hand-written in their app directories.
- Ensures all single-endpoint DNSEndpoints strictly conform to the required dual label and annotation scheme.

---

### 2.5 Componentize Media Rclone Mounts (`media/components/rclone-zurg`)

#### Problem

In `kubernetes/apps/media/`, 17 applications (`sonarr`, `radarr`, `sonarr4k`, `radarr4k`, `bazarr`, `bazarr4k`, `plex`, `jellyfin`, etc.) copy-paste ~100 lines of configuration:

- Container `rclone-zurg` with image, command flags (`--dir-cache-time`, `--vfs-cache-mode`, `--vfs-read-ahead`), env vars, probes, and privileged securityContext.
- HostPath mounts for `/dev/fuse`, `/cache`, `/tmp` (`Bidirectional` mount propagation), and `/aio/remote/zurg` (`HostToContainer`).
- `existingClaim: symlinks` volume mount.

Whenever rclone flags, cache sizing, or image versions need tuning, 17 HelmReleases must be updated individually.

#### Proposal

1. Package this pattern as a reusable component in `kubernetes/apps/media/components/rclone-zurg/` (or via HelmRelease `spec.valuesFrom` ConfigMap).
2. The component provides a Kustomize patch targeting the app's `HelmRelease` that merges the sidecar container and persistence definitions into `spec.values`.
3. Workloads in `media/` simply include the component and provide the app name for `/host-mount/rclone-${APP}-zurg`.

---

### 2.6 Overlay Pattern for 4K Media Workloads

#### Problem

A recursive diff shows that `sonarr4k`, `radarr4k`, and `bazarr4k` are 100% duplicate copies of `sonarr`, `radarr`, and `bazarr` (7 files each), changing only string occurrences of the app name.

Maintaining parallel manifest directories leads to configuration drift (e.g. bugfixes or volume tweaks applied to `sonarr` but forgotten in `sonarr4k`).

#### Proposal

Convert 4K apps into Kustomize overlays of their base 1080p definitions:

1. In `kubernetes/apps/media/sonarr4k/app/kustomization.yaml`:
    ```yaml
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
        - ../../sonarr/app
    patches:
        - patch: |-
              apiVersion: helm.toolkit.fluxcd.io/v2
              kind: HelmRelease
              metadata:
                name: sonarr4k
              spec:
                values:
                  controllers:
                    sonarr:
                      containers:
                        app:
                          env:
                            SONARR__APP__INSTANCENAME: Sonarr 4K
          target:
              kind: HelmRelease
    ```
    Or use Flux Kustomization pointing directly to `path: ./kubernetes/apps/media/sonarr/app` with `postBuild.substitute: APP: sonarr4k`.
2. Deletes ~21 redundant manifest files.
3. Guarantees that upstream improvements to the base apps automatically propagate to 4K instances.

---

### 2.7 Consolidated `servarr-secret` ExternalSecret

#### Problem

Ten applications in the `media` namespace (`sonarr`, `radarr`, `sonarr4k`, `radarr4k`, `prowlarr`, `bazarr`, `bazarr4k`, `swaparr`, `repair`, `warrden`) each declare an `ExternalSecret` querying `/servarr/API_KEY` from Infisical every 12 hours.

#### Implemented Solution

Consolidate into a single shared `ExternalSecret` named `servarr-secret` in `kubernetes/apps/media/common/`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
    name: servarr
spec:
    secretStoreRef:
        kind: ClusterSecretStore
        name: infisical
    target:
        name: servarr-secret
    data:
        - secretKey: API_KEY
          remoteRef:
              key: /servarr/API_KEY
```

#### Scope & ESO Template Boundary

- **5 apps consolidated**: Applications that pass the API key directly to an environment variable (`sonarr`, `radarr`, `sonarr4k`, `radarr4k`, `prowlarr`) consume `servarr-secret` via `valueFrom.secretKeyRef`.
- **5 apps preserved**: Applications that construct complex configuration files inside ESO `template.data` (`bazarr`, `bazarr4k`, `warrden`, `repair`, `swaparr`) keep their own dedicated ExternalSecret. External Secrets Operator v2 templates can only interpolate keys from their own remote data refs and cannot read data from a separate Kubernetes Secret.

---

### 2.8 Componentize Authentik ExtAuth SecurityPolicy (`components/authentik`)

#### Problem

21 `securitypolicy.yaml` manifests duplicate the same 35-line `extAuth` block:

```yaml
spec:
    extAuth:
        failOpen: false
        headersToExtAuth:
            - X-Forwarded-For
            - X-Forwarded-Host
            - X-Forwarded-Proto
            - X-Forwarded-Uri
            - accept
            - authorization
            - cookie
            - user-agent
        http:
            backendRefs:
                - name: authentik-server
                  namespace: authentik
                  port: 80
            path: /outpost.goauthentik.io/auth/envoy
            headersToBackend:
                - Location
                - Set-Cookie
                - X-authentik-email
                - X-authentik-groups
                - X-authentik-name
                - X-authentik-uid
                - X-authentik-username
```

#### Implemented Solution

Create `kubernetes/components/authentik/`:

- Defines `SecurityPolicy/${APP}-auth` targeting HTTPRoute `${APP}-${DOMAIN_SLUG:=480p-com}`.
- Converts **10 of 21** protected apps (the active media set: `sonarr`, `radarr`, `sonarr4k`, `radarr4k`, `bazarr`, `bazarr4k`, `clonarr`, `prowlarr`, `umlautadaptarrex`, `zurg`), plus converts the disabled `altmount` (11 `ks.yaml` entries total).
- **11 apps preserved**: Non-standard configurations (`echo` ×3, `flux-operator`, `konflate`, `grafana`, `prometheus`, `alertmanager`, `victoria-logs`, `vaultwarden-admin`, `kopia`) keep their hand-written SecurityPolicies.

---

### 2.9 Phased Retirement & Decommissioning

1. **Complete VolSync to Kopiur Migration**:
    - 8 applications still referenced `components/volsync` in their `ks.yaml` at the time of writing (example apps from the analysis: `profilarr`, `kometa`, and others); since completed — see `docs/agents/backups.md`.
    - Finishing this migration allows removing the VolSync operator HelmRelease, leftover admission policies, and CRDs.
2. **Decommission Dead TinyAuth Deployments**:
    - `kubernetes/apps/network/tinyauth/` continues running 3 separate deployments (`480p-com`, `brauni-dev`, `riki-boo`) despite Authentik embedded outpost having completely superseded TinyAuth.
    - Deleting the TinyAuth directory cleans up unused routes, reference grants, and DNS endpoints.

---

## 3. Implementation Status

### Phase 1: High-Impact Quick Wins (PRs #1446, #1447, #1449, #1451)

- [x] **PR #1446**: Add `driftDetection: mode: enabled` to `kubernetes/flux/cluster/ks.yaml` and remove boilerplate from 97 HelmReleases.
- [x] **PR #1451**: Centralize `app-template` `OCIRepository` via `kubernetes/components/app-template` across 7 namespaces.
- [x] **PR #1447**: Deploy shared explicit outpost HTTPRoutes on Envoy Gateways (`outpost-routes.yaml`) and delete the 19 per-app `httproute-outpost.yaml` files.
- [x] **PR #1449**: Create shared `servarr-secret` in `media` namespace and consolidate the 5 direct-env ExternalSecrets.

### Phase 2: Kustomize Components & Overlays (PRs #1448, #1450)

- [x] **PR #1450**: Create `kubernetes/components/dnsendpoint` and migrate 39 single-endpoint `dnsendpoints.yaml` files.
- [x] **PR #1448**: Create `kubernetes/components/authentik` extAuth component and migrate 10 media `SecurityPolicy` resources.
- [ ] Convert `sonarr4k`, `radarr4k`, and `bazarr4k` to overlays of their 1080p base configurations.

### Phase 3: Media & Storage Streamlining (Namespace Scope)

- [ ] Extract `rclone-zurg` sidecar and persistence definitions into a reusable media component.
- [ ] Migrate remaining 8 apps from `components/volsync` to `components/kopiur`.
- [ ] Decommission VolSync operator and remove unused TinyAuth manifests.
