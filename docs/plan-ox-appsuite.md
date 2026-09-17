# Plan: Open-Xchange (OX App Suite 8) on the cluster — FULL SUITE

> Status: **DRAFT v2 — scope upgraded to full suite incl. mail backend; D4 still open**
> Owner: brauni · Collaborators: any agent · Track this file until the rollout is done,
> then distill durable findings into `AGENTS.md` and delete/archive this plan.

Purpose: add **Open-Xchange App Suite 8** — complete feature set (mail, calendar,
contacts, tasks, Drive, Documents/Collabora editing, Guard, user guides) **with its own
in-cluster mail backend** (Postfix + Dovecot CE) — to the cluster in its **own namespace**,
following the repo's three-layer Flux model. This file is the single source of truth for
the rollout; agents implementing parts of it should update the checkboxes and notes here.

---

## 0. Decisions

| # | Decision | Status | Resolution |
|---|----------|--------|------------|
| D1 | Mail backend | **decided** | **Full in-cluster stack**: Postfix (SMTP) + Dovecot CE (IMAP/LMTP/Sieve), lab-battery architecture (see §4) |
| D2 | Hostnames | **decided** | `ox.brauni.dev` + `dav.ox.brauni.dev`; Collabora gets `office.ox.brauni.dev` (see §5); mail host `mail.<mail-domain>` (D6) |
| D3 | Namespace | **decided** | `ox` |
| D4 | MariaDB deployment flavor | **open — brauni thinking** | See comparison §3.1. Nothing else in P1 blocks on it besides the MariaDB PR itself |
| D5 | Feature scope | **decided** | **Full App Suite 8**: documents + Collabora + Gotenberg + Guard + office-web + user guides ON. Switchboard/EAS/Booking = explicit opt-in follow-ups (§2.1) |
| D6 | Mail domain | **open** | Which domain receives mail (`brauni.dev`? `480p.com`? dedicated)? Sets MX/SPF/DKIM/DMARC records + mail hostnames |
| D7 | Outbound mail path | **open** | (a) direct: OVH outbound port-25 unblock + PTR + SPF/DKIM, or (b) smarthost relay via an existing provider. Deliverability risk differs hugely (§4.3) |
| D8 | External MUA access | **open** | Thunderbird/phone via IMAP+SMTP-submission from outside the cluster? (adds Dovecot passwd-file sync or LDAP/Keycloak decision, §4.4) — App Suite itself needs neither |

## 1. Research summary (verified 2026-09-17)

Everything below was verified against upstream sources, not assumed:

- **Official deployment model**: OX App Suite 8 ships as OCI images + an official "stack"
  Helm chart, `oci://registry.open-xchange.com/appsuite/charts/appsuite` (current:
  `8.52.928`, app version 8.52). Lab/ops reference: <https://gitlab.open-xchange.com/appsuite/operation-guides>
  (public; the canonical `values.yaml` patterns live in `templates/values.yaml.j2` there).
- **No registry credentials needed**: the stack chart vendors ALL subcharts (`charts/` in
  the tarball — the `appsuite-core-internal/*` subchart repos are private, but we never
  pull them individually), and all container images resolve to the public
  `registry.open-xchange.com/appsuite/*` project (anonymous pull verified, digest pinning
  works — repo requirement). The mail/lab batteries are also published:
  `registry.open-xchange.com/appsuite-operation-guides/{postfix,pypod}` (verified public);
  Dovecot CE uses upstream `dovecot/dovecot`.
- **Istio is NOT required**: `istio.enabled: false` is the chart default. We replicate the
  chart's ingress path table with Envoy Gateway `HTTPRoute`s (§5).
- **Hard requirements** (App Suite 8 Operations Guide "Requirements"):
  - **MariaDB** — see §3, no alternative exists.
  - **Redis 7.4.x** for session storage (`sessiond`) + cache. The chart's built-in
    `redis.*.enabled` deploys Spotahome `RedisFailover` CRs (operator we don't have);
    instead a single small Redis StatefulSet (lab's `redis-light` battery precedent).
  - **S3 object storage** as filestore — Ceph RGW explicitly supported upstream; we have
    the external Rook RGW + `ceph-bucket` OBC pattern (see `kubernetes/apps/niks3`).
  - **IMAP/SMTP/Sieve server** — provided by our own Dovecot CE + Postfix (D1).
- **Documents/Collabora stack is public and chart-integrated**: `core-documents-collaboration`
  (= the WOPI server) is a stack-chart subchart; Collabora Online and Gotenberg are vendored
  **subcharts of core-mw** (`core-mw.collabora-online.enabled` / `core-mw.gotenberg.enabled`)
  whose images the stack chart overrides to public
  `registry.open-xchange.com/appsuite/collabora-online` (digest-pinned in chart defaults)
  and `registry.open-xchange.com/appsuite/gotenberg:8.15.3`. Collabora serves on 9980,
  TLS off (terminated at gateway), ships its own optional Gateway-API route template.
- **Rendered footprint** (middleware-only test render): 11 Deployments ≈ 12Gi at chart
  defaults. Full suite adds core-documents-collaboration, office-web, office-user-guide +
  the Collabora/Gotenberg subcharts + mail stack → roughly **18–20Gi at defaults**, we
  will tune to ~12–14Gi (middleware 3Gi, Collabora 2Gi, dc/ic/spellcheck ≤1Gi each).
  Workers are 3×24Gi/8CPU — fits, but budget carefully (§8).
- **Bootstrap semantics**: chart renders DB credentials from `global.mysql.*` (supports
  `existingSecret`); `core-mw.enableInitialization` runs the initconfigdb Job;
  `core-mw.update.enabled` runs update-task Jobs on chart upgrades (**must be ON** before
  any version bump). After install: `registerserver`, `registerfilestore -t s3://<bucket>`,
  `registerdatabase … --create-userdb-schemas`, then `createcontext`/`createuser` — the lab
  does this via `pypod` against the admin HTTP API; for us: ad-hoc `kubectl exec` into a
  middleware/mwctl pod + the public `appsuite-operation-guides/pypod` image as fallback
  (runbook §9).
- **S3 client knobs** (oxpedia "S3 File Store" / "S3 Client Configuration"):
  `com.openexchange.filestore.s3client.<id>.{endpoint,accessKey,secretKey,region,pathStyleAccess}`.

Licensing note (acceptance needed): App Suite images are publicly pullable, but upstream
positions this as "Software Subscription" territory for production. Homelab use of the
public images is what their own lab tooling does. EAS/Business-Mobility is historically a
**paid** connector — treat as unavailable without a license (§2.1).

## 2. Scope: what "full App Suite 8" means here

### 2.1 In scope (phase 1–4)

| Feature | Chart pieces | Notes |
|---|---|---|
| Mail (webmail) | core-mw + Dovecot CE + Postfix | OX is IMAP/SMTP client; Dovecot holds maildirs; Postfix MX/relay (§4) |
| Calendar / Contacts / Tasks | core-mw (+ chronos etc.) | CalDAV/CardDAV via dav host |
| Drive (files) | core-mw + S3 filestore | previews via documentconverter/imageconverter |
| Documents (text/spreadsheet/presentation **editing**) | `core-documents-collaboration` (WOPI) + `core-mw.collabora-online` + `core-mw.gotenberg` + `office-web` + `office-user-guide` + middleware packages `open-xchange-documents-backend`, capability `documents`+`text/spreadsheet/presentation` | Collabora needs browser reachability → dedicated host `office.ox.brauni.dev` (§5) |
| OX Guard (mail/file encryption) | `guard-ui`, middleware `guard` feature | needs `oxguardpass` secret file, guest SMTP, guard storage (S3 `guardstore` or file) |
| Spellcheck | `core-spellcheck` | on |
| Document/Image preview | `core-documentconverter`, `core-imageconverter`, `core-cacheservice` | on |
| Help | `core-user-guide`, `core-drive-help` | static containers, ~96Mi |
| Admin | `core-mw-admin` role + `/admin` | exposure restricted (§5) |

### 2.2 Opt-in follow-ups (explicitly NOT phase 1)

- **Switchboard** (calls/presence signaling): Node + webRTC/TURN story, extra host or
  `/switchboard`+`/socket.io` routes, redis db. Do after everything else is green.
- **Business Mobility (EAS/`usm-json`)**: historically a licensed OX connector; do not
  plan on it. Verify with OX if ever needed.
- **Booking service** (new 8.52 appointment booking): `bookingservice.enabled` + own DB;
  small, enable when bored.
- **OIDC login via Authentik** instead of DB auth: also unblocks Dovecot OAuth (D8).

## 3. Database: MariaDB is mandatory — no alternative (verified)

The user asked to double-check this. Findings, with sources:

- **App Suite 8**: "OX App Suite Software Subscription v8 uses MariaDB with the InnoDB
  storage engine as its primary data store." Supported table lists **only** MariaDB
  Server / Galera Cluster 10.6.x, 10.11.x, 11.4.x, 11.8.x. The only supported
  DB-as-a-service is AWS RDS **for MariaDB**.
  Source: <https://documentation.open-xchange.com/appsuite/operation-guides/requirements.html>
- **Legacy 7.10.x** supported Oracle MySQL 5.6/5.7 alongside MariaDB, **but**: "Open-Xchange
  does not plan to support MySQL 8 or higher. As MariaDB and MySQL are diverging and cannot
  be assumed to behave identical" — the Oracle-MySQL path is dead-ended and is not part of
  v8 at all. Source: <https://wiki.open-xchange.com/wiki/index.php?title=AppSuite:OX_System_Requirements>
- **PostgreSQL was never supported** in any OX version: the middleware's entire SQL layer
  (configdb, per-context user DBs created by `registerdatabase`, update tasks) speaks the
  MySQL dialect over the MySQL wire protocol. There is no Postgres adapter upstream.
  (Also the reason our CNPG/Postgres operator can't be reused — R1 from first draft.)
- Practical consequence: whatever runs the DB must be wire-compatible MySQL/MariaDB of the
  supported versions. No CNPG, no Cockroach, no Vitess-sharded exotic flavors.

### 3.1 D4 comparison (decide when ready)

| | (a) mariadb-operator | (b) light StatefulSet |
|---|---|---|
| Style | matches repo operator-first pattern (CNPG, Rook) | like lab `mariadb-light`, hand-rolled |
| CRD surface | `MariaDB`/`Database`/`User`/`Backup`/`Restore` CRs, Flux-friendly | plain STS + ConfigMaps + Jobs |
| Backups | `Backup` CR → S3, scheduled, incremental-ish (physical xtrabackup-style + logical) | cronjob `mariadb-dump` → S3, restore manual |
| HA | Galera optional later | none (accept downtime) |
| Cost | +1 operator deployment, CRDs cluster-wide, learning curve | zero extra moving parts |
| Restoration drill | `Restore` CR, documented | manual SQL import |

Full-suite OX makes the DB even more central (configdb + N userdb schemas +
objectcachedb + guard). Both options work for a homelab; (a) gives the better DR story and
matches the repo, (b) is less machinery. **The rest of the plan is agnostic** — only the
`kubernetes/apps/ox/mariadb/` (or `dbms/`) subtree differs.

## 4. Mail backend (full, in-cluster)

Architecture follows the OX lab batteries (both Apache-2.0/MIT-style permissive? — check
license headers when vendoring; the postfix image is published at
`registry.open-xchange.com/appsuite-operation-guides/postfix` so we may not even need to
build it):

```
Internet ──MX 25──► NodePort/LB Service ──► postfix (STS, in): relay_domains=<mail-domain>
                                                  │ LMTP (in-cluster)
                                                  ▼
                                             dovecot-ce (maildir PVC, IMAP 143, sieve 4190,
                                                  │            submission 587, doveadm)
                                                  │ IMAP 143 (in-cluster, master-password auth)
                                                  ▼
                             core-mw  ◄──SMTP 25 (in-cluster)──  users compose mail
                             (sieve filters pushed to dovecot :4190)
Outbound: postfix ──25──► (D7: direct w/ OVH unblock+PTR+DKIM  OR  smarthost relay)
```

Key facts from the batteries:

- **Postfix** (`appsuite-operation-guides/postfix` image, plain StatefulSet + Service):
  lab config relays `<domain>` via `relay_domains`/`transport_maps` to LMTP at dovecot and
  **discards everything else** (`transport: * discard:`) — lab-grade! For us, main.cf needs
  real outbound (or smarthost), TLS (cert-manager cert for `mail.<domain>` STARTTLS),
  message size limits, and DKIM (see gap G1). Chart exposes `main.cf.replace`/`.append`
  ConfigMaps — fully overridable without forking.
- **Dovecot CE** (upstream `dovecot/dovecot` image, StatefulSet + PVC + ConfigMap/Secret):
  ports imap/lmtp/submission/sieve/doveadm; `passwd-file` auth by default; TLS optional
  (we terminate at gateway/in-cluster plaintext for OX; enable TLS for external MUAs only
  if D8=yes); `submission_host: postfix`; OX↔Dovecot auth via **master password**
  (`com.openexchange.mail.masterPassword` in middleware `secretProperties` ↔ dovecot
  `masterauth` secret) — so App Suite users need no password sync; push notifications
  supported (`imapidle` listeners → OX PNS webhooks → switchboard… needs switchboard for
  full push, else poll).
- **Storage**: maildirs on `ceph-block` RWO PVC (single-replica dovecot, ~50Gi to start);
  backups: kopiur/volsync-style snapshot? decide — maildir on block + VolSync kopia or
  plain S3 sync; DB-style dumps don't apply.
- **Provisioning**: OX DB users and Dovecot passwd-file must stay in sync **only if**
  external MUAs (D8) use per-user passwords; the lab's `pypod` battery does exactly this
  (`provision-by-yaml3.py` writes both). Public image available; alternatively a small
  ConfigMap/Secret mounted into dovecot that we generate in the createuser runbook (§9).

### 4.1 Exposure & DNS (inbound)

- SMTP-25 must bypass Cloudflare (no proxy) → dedicated `Service type: LoadBalancer`
  (Cilium L2/BGP announcement — check how `public.brauni.dev` LB is done today and mirror)
  or NodePort 30025 + A record. DNSEndpoint A record `mail.<domain>` → LB IP; MX record
  for the mail domain → `mail.<domain>` (Cloudflare API via external-dns supports MX? —
  our external-dns is DNSEndpoint-driven, so yes via `recordType: MX`).
- IMAPS/submission (993/465/587) exposed only if D8 = yes (same LB service, TLS via
  cert-manager).

### 4.2 Deliverability checklist (D7 = direct)

- [ ] OVH: request outbound port-25 unblock for the account (OVH blocks SMTP egress by
      default on public cloud / VPS ranges)
- [ ] PTR/reverse DNS of the egress IP → `mail.<domain>` (OVH manager)
- [ ] SPF TXT, DKIM (see G1), DMARC records for the mail domain
- [ ] Postfix: helo restrictions, TLS, rate limiting; monitor bounces
- Smarthost alternative: relay via existing provider (e.g. OVH email, mailbox.org,
  SES…) — no unblock/PTR needed, DKIM by provider; still set SPF include + custom
  Return-Path handling if needed.

### 4.3 Gaps in lab batteries (must fix for real use)

- **G1 DKIM**: no signing in the battery. Options: rspamd sidecar/daemon (milter),
  opendkim container, or postfix `smtp_tls_*` only + smarthost signs. Required for D7(a).
- **G2 outbound**: replace `discard:` transport with real relay/smarthost (D7).
- **G3 spam filtering**: none in lab. rspamd would also cover this — decide whether
  homelab wants it (optional, P5).
- **G4 multi-domain**: relay_domains is single-domain in lab; extend if >1 mail domain.

## 5. Envoy Gateway routing table (from the chart's own ingress adapter)

`appRoot` stays `/appsuite`. Rules extracted from chart 8.52.928 `templates/ingress.yaml`
+ `_ingress.tpl`. One `HTTPRoute` per hostname; parentRef
`Gateway/envoy-brauni-dev-public` (ns `network`, sectionName `https`).

Main host (`ox.brauni.dev`) — Gateway API resolves overlaps by specificity, keep
exact-redirects first anyway:

| Match | Backend (port 80) | Filter / notes |
|---|---|---|
| `Exact /` | – | `RequestRedirect` → `/appsuite/` |
| `Prefix /appsuite/api/oxguard` | `<rel>-core-mw-http-api` | rewrite → `/oxguard` + sessionPersistence (cookie) |
| `Prefix /appsuite/api/guardsupport` | `<rel>-core-mw-http-api` | rewrite → `/guardsupport` + sessionPersistence |
| `Prefix /appsuite/api` | `<rel>-core-mw-http-api` | + sessionPersistence |
| `Prefix /api` | `<rel>-core-mw-http-api` | rewrite → `/appsuite/api` + sessionPersistence |
| `Prefix /ajax` | `<rel>-core-mw-http-api` | rewrite → `/appsuite/api` + sessionPersistence |
| `Prefix /appsuite/rt2` | `<rel>-core-mw-http-api` | rewrite → `/rt2`; websocket; long `timeouts.request` |
| `Prefix /pks` | `<rel>-core-mw-http-api` | rewrite → `/pgp` + sessionPersistence (Guard PGP keyserver) |
| `Prefix /admin` | `<rel>-core-mw-admin` | sessionPersistence; **restrict: VPN-only gateway or mTLS SecurityPolicy** |
| `Prefix /advertisement`, `/chronos`, `/preliminary`, `/userfeedback`, `/servlet`, `/realtime`, `/infostore`, `/webservices` | `<rel>-core-mw-http-api` | sessionPersistence |
| `Prefix /api/drive/client/windows/ox/install` | `<rel>-drive-client-windows-ox` | rewrite → `/` (Drive client feed) |
| `Prefix /appsuite/ui` | `<rel>-core-ui` | rewrite → `/ui` |
| `Prefix /appsuite/office` | `<rel>-core-ui-middleware` | rewrite → `/appsuite` (office-web via ui-middleware manifest) |
| `Prefix /appsuite/help` | `<rel>-core-user-guide` | rewrite → `/help` |
| `Prefix /appsuite/help-drive` | `<rel>-core-drive-help` | rewrite → `/help` |
| `Prefix /appsuite/help-documents` | `<rel>-office-user-guide` | rewrite → `/help-documents` |
| `Prefix /appsuite/` (fallback) | `<rel>-core-ui-middleware` | UI shell |

DAV host (`dav.ox.brauni.dev`), separate HTTPRoute:

| Match | Backend | Notes |
|---|---|---|
| `Prefix /.well-known/caldav` | – | redirect → `/caldav/` |
| `Prefix /.well-known/carddav` | – | redirect → `/carddav/` |
| `Prefix /servlet/webdav.infostore/` | `<rel>-core-mw-sync` | header sessionPersistence (`Authorization`) |
| `Prefix /` (fallback) | `<rel>-core-mw-sync` | rewrite → `/servlet/dav/`, header sessionPersistence |

Collabora host (`office.ox.brauni.dev`), separate HTTPRoute — browser loads the Collabora
iframe/websocket directly, so it needs its own hostname (path-prefix-behind-gateway is
possible via Collabora `aliasgroups` but dedicated host is the sane default):

| Match | Backend | Notes |
|---|---|---|
| `Prefix /` | `<rel>-collabora-online`:**9980** | websocket upgrade needed; `core-mw.collabora-online` subchart values: `server_name: office.ox.brauni.dev`, `aliasgroups: [{host: https://office.ox.brauni.dev:443, aliases: []}]`, `extra_params: --o:ssl.enable=false` (default); set wopi `discoveryUrl: https://office.ox.brauni.dev/hosting/discovery` in `core-documents-collaboration`/wopi config |

Notes:
- `sessionPersistence.cookie.name: appsuite-core-mw-http-api-route` replaces the nginx
  sticky annotations; EG ≥1.3 supports it (we run v1.9.x). DAV header-stickiness: confirm
  EG's `sessionPersistence.header` support; fallback none (single replica anyway).
- Switchboard (if ever enabled): `/switchboard/api/` + `/socket.io` extra routes.
- `<rel>` = HelmRelease name (`ox`).
- Gatus: `/appsuite/` → 200 (login page, verify), Collabora `/hosting/discovery` → 200.

## 6. Repo layout to create (three-layer model)

```
kubernetes/apps/ox/
├── namespace.yaml / kustomization.yaml        # ns ox; components: alerts, gateway-route-access
├── appsuite/
│   ├── ks.yaml                                # → ./app; dependsOn mariadb, redis, mail, rook-ceph (OBC)
│   └── app/
│       ├── kustomization.yaml
│       ├── ocirepository.yaml                 # oci://registry.open-xchange.com/appsuite/charts/appsuite @ digest
│       ├── externalsecret.yaml                # Infisical /ox/* (§7)
│       ├── objectbucketclaim.yaml             # ox-filestore (+ ox-guardstore for Guard) via ceph-bucket
│       ├── helmrelease.yaml                   # full-suite values (documents, guard, collabora, gotenberg ON)
│       ├── httproute.yaml / httproute-dav.yaml / httproute-office.yaml
│       ├── dnsendpoints.yaml                  # ox/dav/office CNAMEs + mail A/MX/TXT (§4.1)
│       └── ciliumnetworkpolicy.yaml           # egress: mariadb, redis, rgw, dovecot, postfix, dns
├── mariadb/
│   ├── ks.yaml                                # dependsOn mariadb-operator if D4=a
│   └── app|cluster/                           # MariaDB CR (10.11/11.4, single replica, ceph-block ~30Gi),
│                                             #   configdb/userdb/objectcachedb_v2/guardstore DBs+grants,
│                                             #   Backup CR → OBC ox-mariadb-backups (or dump cronjob for D4=b)
├── redis/
│   ├── ks.yaml
│   └── app/                                   # single redis:7.4 StatefulSet, no persistence
└── mail/
    ├── ks.yaml
    └── app/
        ├── postfix/                           # STS + main.cf ConfigMaps (real outbound, TLS, G1/G2),
        │                                      #   image appsuite-operation-guides/postfix (digest-pinned)
        ├── dovecot/                           # STS + dovecot.conf ConfigMap, passwd-file/secret, maildir PVC
        ├── smtp-loadbalancer.yaml             # Service LB :25 (+993/465/587 if D8)
        └── certificates.yaml                  # cert-manager certs for mail.<domain> (STARTTLS)
```

Plus (D4=a): `kubernetes/apps/dbms/mariadb-operator/{ks.yaml,app/…}` + entry in the dbms
namespace kustomization. Renovate: chart + the OX/battery images; OX tags are
`8.52.<build>` — pin the **chart** and let it carry its tested image set, but
digest-pin images we override ourselves.

## 7. Configuration & secrets

Chart values skeleton (full-suite deltas vs first draft marked):

```yaml
global:
  mysql: {host: ox-mariadb.ox.svc.cluster.local, port: 3306, database: configdb, auth: {…secret…}}
appsuite:
  istio: {enabled: false}
  ingress: {enabled: false}
core-mw:
  enabled: true
  replicas: 1
  defaultScaling: {nodes: {default: {roles: [http-api, sync, admin, request-analyzer]}}}
  update: {enabled: true}
  enableInitialization: true
  features: {status: {documents: enabled, guard: enabled}}          # ← full suite
  packages: {status: {open-xchange-documents-backend: enabled,
                      open-xchange-documentconverter-client: enabled,
                      open-xchange-imageconverter-client: enabled}}
  collabora-online: {enabled: true, server_name: office.ox.brauni.dev, aliasgroups: […]}   # ← full
  gotenberg: {enabled: true}                                        # ← full
  properties:
    com.openexchange.hostname: ox.brauni.dev
    com.openexchange.share.guestHostname: ox.brauni.dev
    com.openexchange.capability.{text,spreadsheet,presentation,document_preview,drive}: "true"
    com.openexchange.capability.{guard,guard-mail,guard-drive,guard-docs}: "true"     # ← Guard
    com.openexchange.guard.oxBackendPath: /appsuite/api/
    com.openexchange.guard.guestSMTPServer: ox-postfix.ox.svc.cluster.local           # ← Guard guests
    com.openexchange.guard.guestSMTPPort: "25"
    com.openexchange.filestore.s3client.ox-filestore.endpoint: http://rook-ceph-rgw-proxmox-s3.rook-ceph.svc.cluster.local:80
    com.openexchange.filestore.s3client.ox-filestore.buckets: ox-filestore
    com.openexchange.filestore.s3client.ox-filestore.region: us-east-1
    com.openexchange.filestore.s3client.ox-filestore.pathStyleAccess: "true"
    com.openexchange.guard.storage.s3.s3FileStore: guardstore                          # ← Guard S3
    com.openexchange.filestore.s3client.guardstore.endpoint: http://…rgw…:80
    com.openexchange.filestore.s3client.guardstore.buckets: ox-guardstore
    com.openexchange.mail.mailServerSource: global                                    # ← in-cluster mail
    com.openexchange.mail.mailServer: ox-dovecot.ox.svc.cluster.local:143
    com.openexchange.mail.transportServerSource: global
    com.openexchange.mail.transportServer: ox-postfix.ox.svc.cluster.local:25
    com.openexchange.mail.filter.server: ox-dovecot.ox.svc.cluster.local              # sieve :4190
    com.openexchange.mail.filter.port: "4190"
    com.openexchange.imap.requireTls: "false"          # in-cluster plaintext; TLS if we wire it later
  secretProperties:                                   # ← from ExternalSecret (see caveat below)
    com.openexchange.filestore.s3client.ox-filestore.accessKey / .secretKey
    com.openexchange.filestore.s3client.guardstore.accessKey / .secretKey
    com.openexchange.mail.masterPassword              # dovecot masterauth
    com.openexchange.cookie.hash.salt / sessiond.encryptionKey / share.cryptKey
    com.openexchange.push.credstorage.passcrypt, hazelcast group pw, jolokia pw
  extraVolumes/extraMounts: oxguardpass secret → /opt/open-xchange/etc/oxguardpass    # Guard
  redis: {hosts: [ox-redis.ox.svc.cluster.local], mode: single}
core-documents-collaboration: {enabled: true}         # WOPI server; discoveryUrl §5
office-web: {enabled: true}                           # ← full suite
office-user-guide: {enabled: true}                    # ← full suite
guard-ui: {enabled: true}                             # ← full suite
switchboard / plugins-ui / bookingservice: {enabled: false}
```

Caveat (implementer!): HelmRelease `values` are static YAML — `{{ .KEY }}` templating does
**not** work with ExternalSecrets. Prefer:
1. `mysql.existingSecret` (native chart support) for DB creds;
2. repo `postBuild.substituteFrom` pattern (`${OX_*}` placeholders + ExternalSecret-produced
   ConfigMap in the **operator-level** Kustomization — mind the kopiur lesson: producer and
   consumer must not share one Kustomization or Flux deadlocks at build time);
3. anything the chart only takes as literal strings → keep in Infisical and splice via 2.

Infisical keys (folder `/ox/`):
`OX_MASTER_ADMIN_PASSWORD`, `OX_MARIADB_ROOT_PASSWORD`, `OX_MARIADB_OX_PASSWORD`,
`OX_S3_ACCESS_KEY/SECRET_KEY` (filestore), `OX_GUARD_S3_ACCESS_KEY/SECRET_KEY`,
`OXGUARDPASS` (guard master password file), `OX_DOVECOT_MASTER_PASSWORD`,
`OX_DOVECOT_USERS_PASSWD` (if D8 passwd-file auth), `OX_POSTFIX_RELAY_*` (D7 smarthost),
`OX_COOKIE_HASH_SALT`, `OX_SESSIOND_ENCRYPTION_KEY`, `OX_SHARE_CRYPT_KEY`,
`OX_CREDSTORAGE_PASSCRYPT`, `OX_HZ_GROUP_PASSWORD`, `OX_JOLOKIA_PASSWORD`.

MariaDB databases: `configdb`, user DB `oxdb` (schemas `oxdb_1..10` via
`registerdatabase --create-userdb-schemas`), `objectcachedb_v2`, (bookingdb only if booking).
Grants: `ox` app user + `root` for init/registration/update jobs.

## 8. Sizing budget (tuned targets)

| Component | limit | notes |
|---|---|---|
| core-mw | 3Gi / 1 CPU | Java; chart default 4Gi, tune down |
| core-documentconverter | 1.5Gi | previews |
| core-imageconverter | 1Gi | |
| core-spellcheck | 512Mi | |
| core-documents-collaboration | 1Gi | WOPI |
| core-cacheservice | 512Mi | |
| core-ui-middleware (+redis sidecar) | 768Mi | |
| core-ui / guides / guard-ui / office-web | ~100Mi each | static |
| collabora-online | 2Gi | documents editing |
| gotenberg | 512Mi | PDF conversion |
| mariadb | 1.5Gi | |
| redis | 256Mi | |
| postfix / dovecot | 256Mi / 512Mi | maildir on PVC |
| **Total** | **~13–14Gi** | spread across 3×24Gi workers; keep middleware+collabora on different nodes if convenient |

## 9. Rollout plan (ordered, with validation gates)

- [ ] **P0 — decisions**: D4, D6, D7, D8 answered. Record above.
- [ ] **P1 — foundations**:
      - [ ] Namespace layer `kubernetes/apps/ox/` (namespace, kustomization, alerts +
            gateway-route-access components).
      - [ ] MariaDB per D4; DBs + grants + Backup. Gate: healthy pod, backup object in S3,
            `mariadb-admin status` green.
      - [ ] Redis StatefulSet `ox-redis` (7.4, digest-pinned, no persistence). Gate: ping.
      - [ ] OBCs `ox-filestore`, `ox-guardstore`. Gate: buckets listed via toolbox pod.
- [ ] **P2 — mail stack**:
      - [ ] Postfix STS with real config (D7 path; DKIM if D7a; smarthost creds if D7b).
      - [ ] Dovecot STS: maildir PVC, masterauth secret, sieve, LMTP; submission host.
      - [ ] SMTP LoadBalancer Service + DNSEndpoint (A `mail.<domain>`, MX, SPF/DMARC TXT,
            DKIM TXT). Gate: external mail TO a test address lands in the maildir
            (swaks/mail-tester from outside); outbound to Gmail lands in spam folder at
            worst, inbox at best — iterate on DNS until mail-tester ≥ 8/10.
- [ ] **P3 — App Suite core (full suite values)**:
      - [ ] ocirepository + helmrelease (§7), HTTPRoutes (§5), DNSEndpoints for ox/dav/office,
            Homepage annotations, CiliumNetworkPolicies.
      - [ ] Flux reconcile; init Job green; all Deployments ready.
            Gate: `curl https://ox.brauni.dev/appsuite/` → 200.
- [ ] **P4 — bootstrap data** (runbook, ad-hoc, NOT GitOps objects):
      - [ ] `registerserver`, `registerfilestore -t s3://ox-filestore`,
            `registerdatabase -n oxdb -m true … --create-userdb-schemas --userdb-schema-count 10`.
      - [ ] `createcontext` + `createuser` (+ Dovecot passwd-file entry if D8).
      - [ ] Login as `<user>@<ctx>`; send+receive mail via our own stack; calendar; drive
            upload; **open a docx in Collabora and edit**; Guard: enable for test user,
            send encrypted mail; sieve filter round-trip.
      - [ ] Record exact commands in §10.
- [ ] **P5 — hardening**: ServiceMonitors + Grafana, alerts (MariaDB backup age, middleware
      OOM/restarts, mail queue depth), resource tuning to §8, Renovate config, /admin
      exposure restriction, Dovecot TLS + external MUA (D8), switchboard/booking opt-ins,
      rspamd (G3).
- [ ] **P6 — distill**: move durable findings to `AGENTS.md`, archive this plan.

## 10. Runbook notes (filled during P4)

- (to be filled with actual exec commands + outputs)

## 11. Risks / open questions

- **R1**: OX upgrade cadence — image tags are build numbers pinned per chart release;
  Renovate must only bump the chart, never individual images. Digest-pin overrides.
- **R2**: Envoy Gateway `sessionPersistence` + `URLRewrite` on the same rule — supported
  on EG ≥1.3 (we run 1.9.x); DAV header-stickiness support to verify (fallback: none).
- **R3**: Mail deliverability (D7a): OVH port-25 unblock + PTR are account-level asks with
  lead time; without them outbound must go smarthost (D7b). DKIM tooling gap G1.
- **R4**: DBs must exist before first middleware boot (init Job) — Flux dependsOn chain
  mariadb → appsuite. Same for OBC buckets before registration (registration is manual
  anyway, so only boot-time needs: mariadb + redis).
- **R5**: Fat Java first boot takes minutes — generous probes, don't panic on slow rollouts;
  Helm install timeout default 15m is enough.
- **R6**: Public-images-but-subscription-positioned upstream: pin versions, upgrade
  deliberately, read operation-guides `UPDATING.md` first.
- **R7**: No kopia/kopiur for MariaDB — operator `Backup` CR (or dump cronjob) + a
  **restore drill** before trusting it. Maildir backups: decide snapshot vs sync.
- **R8**: CiliumNetworkPolicies: middleware egress (mariadb/redis/RGW/dovecot/postfix/DNS),
  collabora egress (documents fetch via middleware), postfix/dovecot ingress from LB +
  middleware; check opencloud CNP as template.
- **R9**: Collabora behind Envoy: websocket upgrade + `server_name`/`aliasgroups` must
  match the public URL exactly or editing fails with cryptic coolwsd errors; the subchart
  ships a Gateway-API route template we can crib settings from.
- **R10**: Guard's `oxguardpass` must be present BEFORE first Guard use; rotating it later
  invalidates guard data — treat as write-once secret.
- **R11**: Dovecot CE battery is single-replica lab-grade; mail durability relies on PVC +
  backups. Acceptable for homelab; don't scale it out (maildir on RWO).
- **R12**: `registerdatabase`/userdb schemas bind MariaDB credentials into configdb rows —
  rotating `OX_MARIADB_OX_PASSWORD` later requires SQL updates in configdb, not just a
  secret roll. Prefer long static password from day one.
