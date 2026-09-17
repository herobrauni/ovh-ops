# Plan: Open-Xchange (OX App Suite 8) on the cluster

> Status: **DRAFT — decisions needed before implementation**
> Owner: brauni · Collaborators: any agent · Track this file until the rollout is done, then
> distill durable findings into `AGENTS.md` and delete/archive this plan.

Purpose: add Open-Xchange App Suite (webmail/groupware: mail, calendar, contacts, tasks,
Drive/Infostore) to the cluster in its **own namespace**, following the repo's three-layer
Flux model. This file is the single source of truth for the rollout; agents implementing
parts of it should update the checkboxes and notes here.

---

## 1. Research summary (verified 2026-09-17)

Everything below was verified against upstream sources, not assumed:

- **Official deployment model**: OX App Suite 8 ships as OCI images + an official "stack"
  Helm chart, `oci://registry.open-xchange.com/appsuite/charts/appsuite` (current:
  `8.52.928`, app version 8.52). Lab/ops reference: <https://gitlab.open-xchange.com/appsuite/operation-guides>
  (public; the canonical `values.yaml` patterns live in `templates/values.yaml.j2` there).
- **No registry credentials needed**: the stack chart vendors ALL subcharts (`charts/` in
  the tarball — the `appsuite-core-internal/*` subchart repos are private, but we never
  pull them individually), and all container images resolve to the public
  `registry.open-xchange.com/appsuite/*` project (anonymous pull verified, Harbor
  token-auth dance works without credentials; digest pinning works — repo requirement).
- **Istio is NOT required**: `istio.enabled: false` is the chart default. The chart also
  ships an ingress-nginx adapter, but we use neither: we replicate its path table with
  Envoy Gateway `HTTPRoute`s (see §5). The chart's own `ingress.enabled: false` default is
  what we want.
- **Hard requirements** (App Suite 8 Operations Guide "Requirements"):
  - **MariaDB** (InnoDB): 10.6 / 10.11 / 11.4 / 11.8 — configdb + per-context user DBs.
    PostgreSQL (CNPG) is **not** usable for OX. The only DB-as-a-service they support is
    RDS-MariaDB; we self-host.
  - **Redis 7.4.x** for session storage (`sessiond`) and cache. The chart's built-in
    `redis.*.enabled` options deploy `RedisFailover` CRs (Spotahome operator) — we do not
    have that operator and don't want sentinel x3+x3 for a homelab; use a single small
    Redis StatefulSet instead (lab's `redis-light` battery is the precedent).
  - **S3 object storage** as filestore (Drive files, PIM attachments) — supported against
    Ceph RGW (explicitly listed upstream). We have Rook external RGW + the `ceph-bucket`
  storageclass/OBC pattern (see `kubernetes/apps/niks3` and the CNPG backups OBC).
  - **IMAP/SMTP server** — App Suite is a mail *client* backend; it needs an IMAP server
    (mail access + sieve for filters) and an SMTP relay. **Open decision, see §2.**
- **Rendered footprint** (helm template with middleware-only roles, documents/guard/switchboard
  off): 11 Deployments, 13 Services ≈
  `core-mw` (Java, 4Gi default limit — tunable down), `core-ui-middleware` (768Mi),
  `core-ui`, `core-user-guide`, `core-drive-help`, `guard-ui` (static, ~96Mi each),
  `core-cacheservice`, `core-documentconverter` (2Gi), `core-imageconverter` (2Gi),
  `core-spellcheck` (2Gi), `appsuite-toolkit` (replicas 0). Workers have 24Gi/8CPU each —
  fits comfortably; we will tune limits down (middleware 2–3Gi, dc/ic/spellcheck ≤1Gi).
- **Bootstrap semantics**: the chart renders DB credentials from `global.mysql.*`
  (supports `existingSecret`); `core-mw.enableInitialization` runs an init job
  (initconfigdb); `core-mw.update.enabled` runs the update-tasks Job on chart upgrades
  (must be ON before any version bump). After install, server/filestore/database must be
  **registered** in configdb (`registerserver`, `registerfilestore -t s3://<bucket>`,
  `registerdatabase ... --create-userdb-schemas`) and a context+user created
  (`createcontext`/`createuser`) — the lab does this via `pypod` against the admin HTTP
  API; for us: ad-hoc `kubectl exec` into a `mwctl`/middleware pod (runbook in §7).
- **S3 client knobs** (oxpedia "S3 File Store" + "S3 Client Configuration"):
  `com.openexchange.filestore.s3client.<id>.{endpoint,accessKey,secretKey,region,pathStyleAccess}`;
  secrets go into `core-mw.secretProperties` (rendered into a Secret by the chart — we
  instead template them from the ExternalSecret into HelmRelease values via
  `{{ .KEY }}`… see §6 caveat).

Licensing note (acceptance needed): App Suite images are publicly pullable, but upstream
positions this as "Software Subscription" territory for production. Homelab/non-committed
use is common (their own lab tooling depends on the public images) — flag if this matters.

## 2. Decisions needed (blocking)

| # | Decision | Options | Proposal |
|---|----------|---------|----------|
| D1 | **Mail backend** | (a) external IMAP/SMTP (existing mailbox provider), (b) deploy Dovecot CE + Postfix in-cluster (lab batteries exist, ~+2 pods, needs MX/SPF/DKIM story), (c) defer mail, start calendar/drive-only | **(a)** phase 1: point at existing provider; revisit (b) later |
| D2 | **Hostname(s)** | `ox.brauni.dev` vs `appsuite.brauni.dev` vs `webmail.brauni.dev`; DAV needs its own hostname (`dav.<host>`) or path routing on the main host | `ox.brauni.dev` + `dav.ox.brauni.dev` |
| D3 | **Namespace name** | `ox` / `open-xchange` / `appsuite` | `ox` |
| D4 | **MariaDB flavor** | (a) `mariadb-operator` (CRD, Galera optional, S3 scheduled backups — new operator in cluster), (b) single MariaDB StatefulSet + cronjob `mariadb-dump` to S3 (mirrors `idlers` sidecar pattern at larger scale) | **(a)** operator: matches repo's operator-first style (CNPG/Rook), gives `MariaDB` CR + `Backup` CR to S3; lives in `kubernetes/apps/dbms/mariadb-operator` |
| D5 | **Feature scope phase 1** | documents/collaboration (Collabora) + Guard off initially? | documents **off**, guard **off**, switchboard off; documentconverter + imageconverter + spellcheck **on** (previews) |

## 3. Target architecture

```
                        ┌────────────────────────── ox namespace ──────────────────────────┐
 ox.brauni.dev ──HTTPS──► Envoy Gateway (envoy-brauni-dev-public, ns network)               │
 dav.ox.brauni.dev        │  HTTPRoute(s) (§5)                                           │
        │                 ▼                                                              │
        │           core-ui-middleware:80  ── UI manifests/static                        │
        │           core-mw-http-api:80    ── /appsuite/api, /ajax, /rt2 (ws), dav, ...  │
        │           core-mw-admin:80       ── /admin                                     │
        │           core-mw-sync:80        ── CalDAV/CardDAV (dav host)                  │
        │           core-ui/user-guide/drive-help/guard-ui:80 (static)                   │
        │                                                                                │
        │           core-mw (Deployment, roles http-api,sync,admin,request-analyzer)     │
        │             ├─► MariaDB (dbms ns or ox ns): configdb, userdb schemas           │
        │             ├─► Redis (single StatefulSet, 7.4, ~128Mi)                        │
        │             ├─► S3 filestore: OBC `ox-filestore` → external Ceph RGW           │
        │             ├─► core-documentconverter / core-imageconverter / core-spellcheck │
        │             └─► IMAP/SMTP/Sieve: external (D1)                                 │
        └────────────────────────────────────────────────────────────────────────────────┘
```

Exposure follows the repo rules: `DNSEndpoint` (CNAME → `public.brauni.dev`,
`dns.scope: all`), Homepage via `gethomepage.dev/*` annotations on the route,
**no Authentik extAuth** (App Suite has its own login; same treatment as opencloud).
Gatus endpoint: `/appsuite/` answers `200` unauthenticated (login page) — confirm during
rollout; otherwise probe `/appsuite/api/…`? (ox serves `401`) and pin via
`gatus.home-operations.com/endpoint` annotation.

## 4. Repo layout to create (three-layer model)

```
kubernetes/apps/ox/
├── namespace.yaml                      # name: _ (namespace: ox set by parent layer)
├── kustomization.yaml                  # ns ox + components: alerts, gateway-route-access
│                                       #   + ./namespace.yaml, ./appsuite/ks.yaml, ./mariadb/ks.yaml, ./redis/ks.yaml
├── appsuite/
│   ├── ks.yaml                         # Flux Kustomization → ./app, dependsOn mariadb, redis, rook-ceph? (OBC)
│   └── app/
│       ├── kustomization.yaml          # ocirepository, externalsecret, helmrelease,
│       │                               #   httproute.yaml, httproute-dav.yaml, dnsendpoints.yaml, cnp
│       ├── ocirepository.yaml          # oci://registry.open-xchange.com/appsuite/charts/appsuite @ digest
│       ├── externalsecret.yaml         # Infisical /ox/* → ox-appsuite-secret (§6)
│       ├── objectbucketclaim.yaml      # bucketName: ox-filestore, storageClassName: ceph-bucket
│       ├── helmrelease.yaml            # chartRef → OCIRepository; values per §5/§6
│       ├── httproute.yaml              # main host path table (§5)
│       ├── httproute-dav.yaml          # dav host (§5)
│       └── ciliumnetworkpolicy.yaml    # egress: mariadb, redis, rgw, imaps/smtps (external), dns
├── mariadb/
│   ├── ks.yaml                         # dependsOn mariadb-operator (if D4=a)
│   └── app/ (or cluster/)              # MariaDB CR, databases (configdb/userdb/objectcachedb_v2),
│                                       #   user grants, Backup CR → S3 OBC ox-mariadb-backups
└── redis/
    ├── ks.yaml
    └── app/                            # StatefulSet redis:7.4.x (digest), ConfigMap, Service, PVC(ceph-block)
```

Plus, if D4=a: `kubernetes/apps/dbms/mariadb-operator/{ks.yaml,app/…}` and a dependency
from `kubernetes/apps/dbms/kustomization.yaml`. Renovate: add the OCI chart + images;
OX tags are `8.52.<build>` — Renovate should pin chart version only and let the chart
carry its (already pinned-per-build) image tags; digest-pin images in values overrides.

## 5. Envoy Gateway routing table (from the chart's own ingress adapter)

`appRoot` stays `/appsuite` (chart default; deep assumption in path structure).
All rules below were extracted from `appsuite/templates/ingress.yaml` +
`templates/_ingress.tpl` of chart 8.52.928. One `HTTPRoute` per hostname, parentRef
`Gateway/envoy-brauni-dev-public` (ns `network`, sectionName `https`).

Main host (`ox.brauni.dev`) — rule order matters (Gateway API: most specific match wins;
Envoy Gateway resolves overlaps by specificity, keep exact-redirects first anyway):

| Match | Backend (port 80) | Filter / notes |
|---|---|---|
| `Exact /` | – | `RequestRedirect` → `/appsuite/` |
| `Prefix /appsuite/api/oxguard` | `<rel>-core-mw-http-api` | `URLRewrite` → `/oxguard` + sessionPersistence |
| `Prefix /appsuite/api/guardsupport` | `<rel>-core-mw-http-api` | rewrite `/guardsupport` + sessionPersistence |
| `Prefix /appsuite/api` | `<rel>-core-mw-http-api` | no rewrite + sessionPersistence |
| `Prefix /api` | `<rel>-core-mw-http-api` | rewrite → `/appsuite/api` + sessionPersistence |
| `Prefix /ajax` | `<rel>-core-mw-http-api` | rewrite → `/appsuite/api` + sessionPersistence |
| `Prefix /appsuite/rt2` | `<rel>-core-mw-http-api` | rewrite → `/rt2`; websocket; long `timeouts.request` |
| `Prefix /pks` | `<rel>-core-mw-http-api` | rewrite → `/pgp` + sessionPersistence |
| `Prefix /admin` | `<rel>-core-mw-admin` | sessionPersistence; consider not exposing publicly |
| `Prefix /advertisement`, `/chronos`, `/preliminary`, `/userfeedback`, `/servlet`, `/realtime`, `/infostore`, `/webservices` | `<rel>-core-mw-http-api` | sessionPersistence |
| `Prefix /appsuite/ui` | `<rel>-core-ui` | rewrite → `/ui` |
| `Prefix /appsuite/help` | `<rel>-core-user-guide` | rewrite → `/help` |
| `Prefix /appsuite/help-drive` | `<rel>-core-drive-help` | rewrite → `/help` |
| `Prefix /appsuite/` (fallback) | `<rel>-core-ui-middleware` | UI shell |

DAV host (`dav.ox.brauni.dev`), separate HTTPRoute:

| Match | Backend | Notes |
|---|---|---|
| `Prefix /.well-known/caldav` | – | redirect → `/caldav/` |
| `Prefix /.well-known/carddav` | – | redirect → `/carddav/` |
| `Prefix /servlet/webdav.infostore/` | `<rel>-core-mw-sync` | header-sticky on `Authorization` → use `sessionPersistence: header` |
| `Prefix /` (fallback) | `<rel>-core-mw-sync` | rewrite → `/servlet/dav/`, header-sticky |

Notes:
- `sessionPersistence` (Gateway API `cookie` mode) replaces the chart's nginx
  `session-cookie-name: appsuite-core-mw-http-api-route`; Envoy Gateway supports
  `sessionPersistence.cookie.name`. With Redis-backed sessions this is belt-and-braces,
  but keep it for the DAV sync endpoints especially.
- `businessmobility` (EAS) and `switchboard` routes are out of scope phase 1.
- `<rel>` = HelmRelease name (`ox`), matching `ox-common.names.fullname` = `<release>-<chart>`.
- Verify in-cluster: `/appsuite/` must answer 200 unauthenticated (login page) before
  flipping Gatus on.

## 6. Configuration & secrets

Chart values skeleton (see lab `values.yaml.j2` for the full upstream reference; keep our
diff minimal and documented):

```yaml
global:
  mysql: {host: ox-mariadb.ox.svc.cluster.local, port: 3306, database: configdb, auth: {…from secret…}}
  extras: {monitoring: {enabled: true}}   # after observability is wired
appsuite:
  istio: {enabled: false}
  ingress: {enabled: false}               # we bring our own HTTPRoutes
core-mw:
  enabled: true
  replicas: 1
  defaultScaling: {nodes: {default: {roles: [http-api, sync, admin, request-analyzer]}}}
  update: {enabled: true}                 # update-task Job on upgrades
  enableInitialization: true              # first install only; flip off after? (decide: harmless to keep)
  properties:
    com.openexchange.hostname: ox.brauni.dev
    com.openexchange.share.guestHostname: ox.brauni.dev
    com.openexchange.filestore.s3client.ox-filestore.endpoint: http://rook-ceph-rgw-proxmox-s3.rook-ceph.svc.cluster.local:80
    com.openexchange.filestore.s3client.ox-filestore.buckets: ox-filestore
    com.openexchange.filestore.s3client.ox-filestore.region: us-east-1
    com.openexchange.filestore.s3client.ox-filestore.pathStyleAccess: "true"
    com.openexchange.mail.mailServerSource: global            # D1(a): external IMAP
    com.openexchange.mail.mailServer: <imap-host>:993
    com.openexchange.mail.transportServerSource: global
    com.openexchange.mail.transportServer: <smtp-host>:465/587
    com.openexchange.mail.filter.server: <sieve-host>          # if available, else disable filter capability
  secretProperties:                       # chart renders these into the middleware Secret
    com.openexchange.filestore.s3client.ox-filestore.accessKey: "{{ .S3_ACCESS_KEY }}"
    com.openexchange.filestore.s3client.ox-filestore.secretKey: "{{ .S3_SECRET_KEY }}"
    com.openexchange.cookie.hash.salt: "{{ .COOKIE_SALT }}"
    com.openexchange.sessiond.encryptionKey: "{{ .SESSIOND_KEY }}"
    com.openexchange.share.cryptKey: "{{ .SHARE_CRYPT_KEY }}"
  redis: {hosts: [ox-redis.ox.svc.cluster.local], mode: single}
core-documents-collaboration: {enabled: false}   # D5
office-web / office-user-guide: {enabled: false}
switchboard: {enabled: false}
plugins-ui / wopi-server: {enabled: false}
guard-ui: {enabled: false}                        # phase ≥2 with guard
core-mw.features.status: {documents: disabled, guard: disabled}
```

Caveat (implementer!): HelmRelease `values` are static YAML in Git — templating
`{{ .KEY }}` there does **not** work with ExternalSecrets. Two viable patterns:
1. `mysql.existingSecret` (supported natively) + keep only non-DB secrets in
   `secretProperties`, and inject those via the chart's secret-value indirection if it
   supports `valueFrom`… (check `core-mw` `secretProperties` rendering; if string-only,
   use pattern 2).
2. Follow the repo's `postBuild.substituteFrom` pattern (as used for kopiur SFTP config):
   plain `${OX_*}` placeholders in the HelmRelease + a ConfigMap produced by an
   ExternalSecret living in the **operator-level** (appsuite `ks.yaml`) Kustomization —
   mind the kopiur lesson: the producing ExternalSecret must NOT live in the same
   Kustomization whose `postBuild` consumes it (Flux build-order deadlock).

Infisical keys (folder `/ox/`):
`OX_MASTER_ADMIN_PASSWORD`, `OX_MARIADB_ROOT_PASSWORD`, `OX_MARIADB_OX_PASSWORD`,
`OX_S3_FILESTORE_ACCESS_KEY`, `OX_S3_FILESTORE_SECRET_KEY` (or consume the OBC-created
secret directly — decide; OBC secret name = claim name), `OX_COOKIE_HASH_SALT`,
`OX_SESSIOND_ENCRYPTION_KEY`, `OX_SHARE_CRYPT_KEY`, `OX_CREDSTORAGE_PASSCRYPT`,
`OX_HZ_GROUP_PASSWORD`, `OX_JOLOKIA_PASSWORD`. Master admin credentials for the
registration CLTs: `oxadmin_master` + password.

MariaDB databases to create (lab parity): `configdb` (shared, `utf8mb4`), user DB
`oxdb` with schemas `oxdb_{1..N}` (created by `registerdatabase --create-userdb-schemas`),
`objectcachedb_v2` (imageconverter object cache), optionally `cacheservicedb` if
core-cacheservice uses MySQL (it does by default — check its values). Grants: one `ox`
app user + `root` for init/registration.

## 7. Rollout plan (ordered, with validation gates)

- [ ] **P0 — decisions**: D1–D5 answered by brauni. Record answers in §2.
- [ ] **P1 — foundations** (no OX yet):
      - [ ] Namespace layer `kubernetes/apps/ox/` (namespace, kustomization with alerts +
            gateway-route-access components, empty ks placeholders).
      - [ ] MariaDB: operator (D4a) or StatefulSet; `MariaDB` CR `ox-mariadb` (10.11 or
            11.4, single replica, `ceph-block` PVC ~20Gi), databases + users via
            `mariadb.org/v1` `Database`/`User` CRs or init SQL Job; `Backup` CR → S3.
            Gate: `kubectl -n ox exec ox-mariadb-0 -- mariadb-admin status` green, backup
            object lands in bucket.
      - [ ] Redis StatefulSet `ox-redis` (7.4-alpine digest-pinned, emptyDir/`appendonly
            no`, no persistence needed — cache/sessions). Gate: `redis-cli ping`.
      - [ ] OBC `ox-filestore` (ceph-bucket). Gate: ObjectBucket ready, credentials
            secret exists; `s3cmd ls` from a toolbox pod.
- [ ] **P2 — App Suite core**:
      - [ ] `ocirepository.yaml` pinned to chart `8.52.928` digest; `helmrelease.yaml`
            with §6 values (init ON, update tasks ON, single replica everywhere).
      - [ ] HTTPRoutes + DNSEndpoint + Homepage annotations + CiliumNetworkPolicy
            (egress: mariadb, redis, RGW, external IMAP/SMTP, DNS, kube-apiserver? no).
      - [ ] Flux reconcile; watch `ox-core-mw` init Job succeed and Deployment go ready.
            Gate: `curl -k https://ox.brauni.dev/appsuite/` → 200 login page.
- [ ] **P3 — bootstrap data** (runbook, ad-hoc, NOT GitOps objects):
      - [ ] `registerserver -A oxadmin_master -P … -n <server_name>`
      - [ ] `registerfilestore -A … -P … -t s3://ox-filestore -s 104857600 -x 50000`
      - [ ] `registerdatabase -A … -P … -n oxdb -m true -H ox-mariadb.ox…:3306 -u … -p …
            -x 50000 --create-userdb-schemas --userdb-schema-count 10`
      - [ ] `createcontext` + `createuser` (admin user + personal user).
      - [ ] Login via UI with `<user>@<ctx-id>`; send/receive a mail (D1a), create a
            calendar entry, upload a Drive file → verify objects appear in the
            `ox-filestore` bucket and mail flows over IMAP/SMTP.
      - [ ] Record exact commands incl. pod/exec invocation in this file (§8) for reuse.
- [ ] **P4 — hardening & observability**:
      - [ ] `global.extras.monitoring.enabled: true` → ServiceMonitors (check
            Prometheus Operator CRDs pick them up in `observability`), Grafana dashboard?
      - [ ] Tune resources down (middleware ~3Gi limit, dc/ic/spellcheck ≤1Gi, Java opts).
      - [ ] Alerts: PXBackupMissing-style rule for MariaDB backups; middleware
            restart/OOM alert; gatus endpoint.
      - [ ] Renovate: chart + image digests; `minimumReleaseAge` for OX chart (stability).
      - [ ] Decide `/admin` exposure (keep behind VPN/Tailnet-only gateway? or mTLS via
            Envoy Gateway SecurityPolicy `tls` client cert?).
- [ ] **P5 — optional features (later PRs)**: Guard (PGP mail encryption), documents
      (Collabora in-cluster), switchboard (calls), businessmobility/EAS, OIDC login
      against Authentik instead of DB auth, pypod-style declarative provisioning.

## 8. Runbook notes (filled during P3)

- (to be filled with actual exec commands + outputs)

## 9. Risks / open questions

- **R1**: OX chart upgrade cadence — image tags are build numbers (`8.52.207`); the
  stack chart pins them per chart release. Renovate must only bump the chart, never
  individual images, or we desync from tested combos. Digest-pin every image in values.
- **R2**: `sessionPersistence` + `URLRewrite` on the same rules: verify Envoy Gateway
  applies both (supported in EG ≥1.3 — we run v1.9.x, fine). DAV header-based stickiness
  via `sessionPersistence.header` — confirm EG support; fallback: none (single replica).
- **R3**: External IMAP with OAuth (Gmail/Outlook) needs OX Guard/OAuth plugins — D1a
  assumes plain password LOGIN or an ISP mailbox.
- **R4**: `objectcachedb_v2`/cacheservice MySQL schemas must exist before first boot or
  the init Job fails — order P1 DBs before P2 HelmRelease (Flux `dependsOn` chain).
- **R5**: OX middleware is a fat Java app: first boot + init tasks take minutes — set
  generous startup probes; do not let Helm install timeout (default 15m ok).
- **R6**: The `appsuite` chart is 8.x "Software Subscription" flavored: public images but
  no community LTS channel promises — pin versions, upgrade deliberately (chart
  `UPDATING.md` in operation-guides documents breaking changes).
- **R7**: No kopia/kopiur for MariaDB — backups via mariadb-operator `Backup` CR to S3
  (consistent with CNPG barman approach). Restore drill before trusting it.
- **R8**: cilium NP: middleware needs egress to external IMAP/SMTP (SNI through
  cloudflare-tunnel? no — direct egress via nodes); check existing egress CNP patterns
  (`kubernetes/apps/selfhosted/opencloud/app/ciliumnetworkpolicy.yaml`).

## 10. Validation checklist (final gate)

- [ ] `task reconcile` clean; `kubectl -n ox get pods,hr,sc` all green
- [ ] `flate test all -p ./kubernetes/flux/cluster` passes locally & in CI
- [ ] Login → mail send/receive, calendar, contacts, drive upload/download, document
      preview (docconverter), sieve filter (if provider supports)
- [ ] CalDAV/CardDAV from a client against `dav.ox.brauni.dev` (well-known redirects)
- [ ] Backup CR produced a restorable dump; gatus endpoint green; Homepage entry visible
- [ ] `util/check_drift_detection.sh` green for the new HelmReleases
```
