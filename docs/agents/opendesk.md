# openDesk CE — what lives here, and what deliberately does not

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when touching
`kubernetes/apps/opendesk/`.

## The shape problem (read this first)

openDesk is **35+ Helm charts orchestrated by Helmfile**, not a chart. Upstream's requirements:

- apps deploy **in order**, and migrations run before *and* after application upgrades,
- secrets are derived from a `MASTER_PASSWORD` at template time,
- the only supported ingress controllers are `haproxy-ingress` and the deprecated `ingress-nginx` —
  Gateway API is planned "ideally end of 2026",
- minimum footprint 12 cores / 32 GB RAM for evaluation.

Upstream's own GitOps guidance is "run helmfile, or pre-render with `helmfile template`" — and the
pre-render explicitly embeds all secrets into the YAML, so it cannot live in this public repo.

Therefore this directory holds **everything that is Flux-shaped** and nothing else:

| In Flux (this repo) | Out of band (helmfile) |
| --- | --- |
| `haproxy-ingress` controller (openDesk needs it; the cluster has Envoy/Gateway API only) | the 35 charts themselves |
| `database-init` Job: 12 Postgres databases + owning roles on `postgres18` | app config that only lives in openDesk values |
| `opendesk-dragonfly`: Redis-protocol cache/coordinator with password + `--dbnum` | migrations runner |
| `opendesk-credentials` ExternalSecret (DB roles, superuser, Redis password) | TLS certificates (cert-manager `Certificate`s, created by the charts) |
| `values/dev-values.yaml.gotmpl`: the override that points openDesk at the above | |

Deploy: see the header of `values/dev-values.yaml.gotmpl`. The values file is version-controlled here and
copied into the pinned upstream checkout at apply time — that copy is the one deliberately-not-GitOps step,
because 35 hand-written HelmReleases would drift on every openDesk release (they do rolling technical
releases; v1.20.4 was current when this landed) and would sidestep their ordering/migration logic.

## Reuse map

| openDesk needs | Provided by | Notes |
| --- | --- | --- |
| PostgreSQL 15.x | `postgres18-rw.dbms.svc.cluster.local`, database per component | 12 databases, owner per DB so XWiki can create sub-wiki schemas and OpenProject can migrate |
| Redis 7.x | `opendesk-dragonfly` (Dragonfly, RESP) | needs `--dbnum>=9`: openDesk uses DB 0 (intercom/OX), 4/5 (Nextcloud cache+sessions), 7/8 (Notes) |
| Memcached | **bundled** | OpenProject + UMS self-service need it, cluster has no memcached; it is tiny |
| Object storage | **bundled SeaweedFS** | see gap below |
| Ingress | `haproxy-ingress` at `10.10.8.20` | Cilium LB IPAM; ports 80/443 must reach it (DNAT on PVE or a Cloudflare tunnel route) |
| TLS | cert-manager, `letsencrypt-production` | override upstream's default `letsencrypt-prod` |
| Storage | `ceph-block` (RWO) | no RWX; openDesk runs without it |

## The database-init Job

`database-init` creates the databases openDesk expects to already exist (its charts do not create them when
`databases.*.host` points at an external server). It is idempotent: existing roles get their password
re-applied from the Secret, existing databases are untouched, so re-running after deleting the Job is safe.

**Keep the `pair` list in sync** with `helmfile/environments/default/database.yaml.gotmpl` of the pinned
openDesk version — a minor bump can add a component and therefore a database. Current list: keycloak,
keycloak_extensions, matrix_authentication, nextcloud, notes, openproject, oxconnector, matrix (Synapse),
nubus_authsession, guardianmanagementapi, selfservice, xwiki. The two Cassandra entries (Dovecot ACL/dictmap)
and the MariaDB one (OX App Suite) are Enterprise/OX-only and intentionally absent, matching the disabled apps.

## Disabled apps and why

`jitsi` (UDP 10000 on a public IP, not forwarded), `oxAppSuite` + `postfix` + `dovecot` (mail is Stalwart's
job, and OX additionally demands MariaDB with root), `mariadb` (only OX), `redis` (replaced by Dragonfly).
`seaweedfs` and `memcached` stay bundled; see the table.

## Known gaps

- **Object storage is not reused.** openDesk reads the access key ID from a `username` key inside the same
  Secret as the secret key; Rook's `ObjectBucketClaim` produces `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`
  with no `username`, and its values file cannot reference env vars. Bridging that needs either a
  `CephObjectStoreUser` plus a reshaped Secret, or a small controller — until then SeaweedFS carries the
  blobs inside the namespace.
- **Fit is tight.** Upstream's minimum is 12 c / 32 GB. This cluster has ~24 c and ~72 GB on the three
  workers but the control planes run at ~95 % memory, so openDesk must be pinned to workers
  (`nodeSelector`/`taints`) before it is switched on, and the residents (`media`, `observability`,
  `selfhosted`, `dbms`) already request ~46 GiB.
- **Ingress exposure is unfinished**: `10.10.8.20` needs 80/443 from wherever clients come from. Today the
  PVE hosts DROP both and all public HTTP runs through Cloudflare Tunnel → Envoy Gateway.
- No `helmfile` runner in Flux, by design (see above). If the apply must be automated later, the honest
  option is a Job that clones the pinned tag and runs `helmfile apply`, not 35 HelmReleases.
