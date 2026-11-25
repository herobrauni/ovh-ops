# Stalwart mail cluster — topology, bootstrap, traps

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when touching
`kubernetes/apps/stalwart/`.

Stalwart v1 is a single binary with all its state in shared stores. This namespace runs it as an
active-active cluster: three `stalwart` pods (one per worker), a Dragonfly instance as in-memory store
and coordinator, and `postgres18` as the data, blob, and search store.

## Topology and why it looks like this

```
                 MX/A: three grey-cloud records, one per PVE host
   PVE1 <PVE1_PUB>         PVE2 <PVE2_PUB>         PVE3 <PVE3_PUB>
        nft DNAT                nft DNAT                nft DNAT
           v                        v                        v
   w-ovhsbg1 :30025/30587/30465/30993/30419/30443   (NodePorts, ETP Local)
        v                        v                        v
   stalwart-0                stalwart-1                stalwart-2
        \________________________|________________________/
                    Postgres + Dragonfly
```

- **One public IPv4 per PVE host already exists** (`vmbr0` on each), and each worker already egresses
  through its _own_ host (`w-ovhsbg1 -> PVE1`, `w-ovhsbg2 -> PVE2`, `w-ovhsbg3 -> PVE3`, verified with
  pinned probe pods). That symmetry is what 1:1 DNAT needs. Never point a worker's default route at
  another host's gateway.
- `externalTrafficPolicy: Local` on `stalwart-mail` is load-bearing: the public IP that accepted a
  connection must send the reply, so Cilium must not forward the connection to another node.
  Consequence: if `stalwart-<i>` is down, `PVE_i:25` refuses and senders retry the other two IPs.
  There is no floating IP and no BGP — steering is DNS only.
- Proxmox HA **must not live-migrate the three worker VMs** (they are HA resources `vm:184-186`).
  Moving a worker desynchronises the worker↔IP mapping; remove that IP from DNS first if a worker has
  to be evacuated.

## In-memory store + coordinator: Dragonfly, not Keep, not Valkey

Stalwart needs the store for locks (no double delivery), rate-limit counters, greylisting entries,
short-lived tokens, and — as coordinator — for cluster events such as cache invalidations.

Upstream supports: Stalwart Keep, Redis/Valkey (single, cluster, sentinel, sharded). **Dragonfly is not
on that list.** It speaks RESP and implements the pieces this workload needs (string/counter ops with
expiry, `SET NX PX` locks, pub/sub), so it is plausible - but "plausible" is the strongest claim
available, and that is exactly what this lab is for.

Choices and their costs:

- **Keep** was the first choice and is upstream's recommendation, but it requires `hostNetwork`
  (`members` holds IP literals) and therefore `privileged` Pod Security. Rejected to keep privileges in
  check; it is the fallback if Dragonfly misbehaves and that trade becomes acceptable.
- **Valkey** is fully supported but is another StatefulSet to operate here; it stays the fallback if
  the store has to be beyond reproach.
- **Dragonfly** reuses the operator and component the cluster already runs for five other apps
  (`${APP}-dragonfly`, snapshot PVC, PodMonitor, CiliumNetworkPolicy). Zero new moving parts.
  Runs as a single replica because the shared component snapshot PVC is `ReadWriteOnce` (`ceph-block`);
  multiple replicas would hit Multi-Attach errors on the volume across nodes. With 5-minute snapshots,
  recovery on pod restart takes seconds.

Known Dragonfly gaps that could bite (`--default_lua_flags=allow-undeclared-keys` is already set by the
component, which removes the most common one): no `MODULE LOAD`, no `FUNCTION`/`FCALL`, `CLIENT TRACKING`
only with `BCAST`/`PREFIX`, `OBJECT ENCODING`/`WAITAOF` absent, no Sentinel. If Stalwart ever leans on
one of those, the symptom is specific and quiet - watch for `store.not-supported`,
`Failed to lock event`, or duplicated deliveries, and check whether cache invalidation still crosses
nodes after a settings change.

### Verifying the store actually works across nodes

1. Both `stalwart` pods up, `kubectl -n stalwart logs deploy/stalwart-dragonfly`-adjacent logs clean,
   no `store.not-supported` in the server logs.
2. Connect IMAP to `stalwart-0` and to `stalwart-1`, confirm identical mailbox state.
3. Change something visible (e.g. a mailbox quota) against node A, re-read via node B - a stale cache
   shows up as the old value persisting.
4. Delete `stalwart-0`, confirm `stalwart-1` keeps serving and the queue drains.
5. `kubectl -n stalwart rollout restart deploy/stalwart-dragonfly`, confirm the single pod restarts,
   loads snapshot from PVC, and the Stalwart nodes reattach (a brief store outage; expect log noise, not lost mail).

## Traps in this deployment

- **`replicas: 1` during bootstrap** (`helmrelease.yaml`). Raising replicas alone does not create a cluster:
  three pods would share the database but have no coordinator, so caches would never invalidate across
  nodes. The bootstrap sequence below is what turns one server into a cluster.
- **`capabilities.drop: [ALL]` + `add: [NET_BIND_SERVICE]`** is mandatory, not cargo cult: the image
  carries `setcap cap_net_bind_service` on the binary, and exec of a file-capability binary needs that
  capability in the bounding set even when every listener is high-numbered. Dropping it yields
  `exec /usr/local/bin/stalwart: operation not permitted`.
- **`readOnlyRootFilesystem` needs the `/var/log/stalwart` emptyDir** (default file tracer). Also mount
  `/var/lib/stalwart` and `/tmp`.
- **The store has no password.** It is scoped by the component's CiliumNetworkPolicy to `${APP}` pods.
  If the store ever leaves that blast radius, move to an ACL file (`aclFromSecret`) and pass the
  password to Stalwart.

## Secrets (all under Infisical `/stalwart/`)

| Key                                                        | What                                                                                                             |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `/cloudnative-pg/stalwart_postgres_username` / `_password` | DB role, already created: username must be `stalwart` because it is hardcoded as `authUsername` in `config.json` |

All database credentials exist in Infisical (`prod`, project `ovh-ops-u1ua`). The database and role themselves are created
by the `01-init-db` init container on first start - `components/cnpg` ships only the credential
ExternalSecrets, so an app that forgets the init container fails readiness against a missing database.
Writes to the Infisical API need `projectSlug`; reads need `workspaceSlug`, and a new secret path needs a
folder first (`POST /api/v1/folders` with `workspaceId`).

Blobs and search indexes live directly in PostgreSQL (`Default` store backend), avoiding any S3/RGW dependency
or separate object credentials.

## Bootstrap (the only part that is not declarative)

Ordering is enforced by the server: store/coordinator settings live in Postgres, and a coordinator is
rejected while the in-memory store is still the local default.

1. Secrets already exist (see table). If they are rotated, the ExternalSecrets pick the change up within
   their 12h refresh; a missing key leaves them in `SecretSyncedError` and nothing starts.
2. Let Flux apply. `stalwart-0` starts (`replicas: 1`) with `STALWART_RECOVERY_ADMIN` set and
   `STALWART_RECOVERY_MODE: "true"` enabled so the WebUI accepts plain HTTP over port-forward
   without throwing `Unknown client id`; confirm `/healthz/ready` is 200 and `stalwart-dragonfly` is Running.
3. `kubectl -n stalwart port-forward svc/stalwart-mgmt 8081:8080`, sign in as the recovery admin.
4. Add the mail domain under _Directory > Domains_ (e.g. `brauni.dev`), then create a permanent administrator
   account under _Directory > Accounts_ and sign in with it.
5. Set, in this exact order, verifying each applies:
    - **Blob Store**: `Default` (or PostgreSQL store `postgres18-rw.dbms.svc.cluster.local:5432/stalwart`).
    - **Search Store**: `Default` (the shared Postgres data store).
    - **In-Memory Store**: Redis variant, `redis://stalwart-dragonfly.stalwart.svc.cluster.local:6379`
      (that is `STALWART_REDIS_URL`), no password.
    - **Coordinator**: `Default` (reuses the in-memory store connection).
6. Drop `STALWART_RECOVERY_ADMIN` from Infisical and remove `STALWART_RECOVERY_MODE` from `helmrelease.yaml`.
   Since `stalwart-secrets` only carried this bootstrap credential, remove `kubernetes/apps/stalwart/stalwart/app/externalsecret.yaml`
   (and its `envFrom` in `helmrelease.yaml` and reference in `kustomization.yaml`) so no empty Secret remains.
   Flip `controllers.stalwart.replicas` to `3` in the same change.
7. Verify the three pods are on three distinct nodes (`kubectl -n stalwart get pods -o wide`, enforced by
   `topologySpreadConstraints`), all three appear under _Settings > Cluster_, and run the cross-node checks above.

## OIDC / SSO for the webmail (Bulwark)

Bulwark (`webmail.480p.com`) does not talk to a mail protocol with a password: it takes the **IdP's access
token and sends it as the JMAP bearer token** to Stalwart. So SSO in the webmail needs trust configured on
**both** sides — authentik issues the token, Stalwart must accept it as a resource server.

Stalwart only accepts a third-party token when an **OpenID Connect directory** exists _and_ is the default
directory (`Authentication.directoryId`, Settings › Authentication › General). Traps:

- **No fallback to the internal directory.** Once the default directory is an external one, every sign-in of
  a domain it serves is checked against it, so existing local `argon2` passwords stop authenticating on
  IMAP/SMTP/JMAP. Mail clients then need app passwords (or OAuth). Bounding this to one domain needs a
  per-domain `directoryId`, which is **Enterprise-only** — Community has exactly one default directory.
- **Settings are DB-resident, not GitOps.** Directory objects live in the `stalwart` database in postgres18
  (registry tables `l`/`d`), created through the WebUI; `config.json` only bootstraps the DataStore. Changes
  to a Directory or to `directoryId` apply after a **ReloadSettings**. There is nothing to diff in Git, so a
  restored/partial database silently loses SSO — check before blaming the app.
- **Values that matter** (verified against authentik 2026.8): `issuerUrl` must equal `iss` _exactly_, and
  authentik publishes it **with** a trailing slash (`https://sso.brauni.dev/application/o/bulwark/`).
  authentik serves no RFC 8414 document (404), so discovery must fall back to
  `/.well-known/openid-configuration` (it does). authentik access tokens are RS256 JWTs with `aud` = the
  **client id** (`bulwark`) → that value has to be in `acceptedAudiences`. Their scopes are only
  `openid email profile offline_access`, none of which Stalwart knows, so `unscopedTokens` must not stay at
  `reject` (`interoperable`, or `full` for the account-management surface a webmail uses — safe here because
  the audience is pinned to one client). `claimUsername: email` maps the account without needing
  `usernameDomain`.
- **Symptom to recognise:** Bulwark's generic "Sign-in did not work / We could not finish signing you in"
  page (`oauth_error.token_exchange_failed`) appears _after_ a successful OAuth round trip — the callback,
  `/api/auth/token` and even the forced refresh all return 200, the app then fails on the JMAP sign-in. Prove
  which side owns it by hand:

    ```sh
    curl -sS -D- -o /dev/null -H "Authorization: Bearer <access-token>" \
      https://stalwart.480p.com/jmap/session
    ```

    `401 ... Bearer realm="Stalwart Server", resource_metadata=".../oauth-protected-resource/..."` means
    Stalwart is still advertising **its own** authorization server and validated nothing — no OIDC directory
    in play. A missing `offline_access` scope mapping on the authentik provider breaks the same login one step
    earlier (instant logout instead of an error page); see `docs/agents/authentik.md`.

### The authentik app tile only opens a URL

Clicking the Bulwark entry on `sso.brauni.dev` is a plain link to `meta_launch_url`; it does **not** start
an OIDC flow. Without help, the user lands on Bulwark's own login form and looks "not logged in". Bulwark
has the two switches that make the tile land in the inbox (`OAUTH_ONLY` + `AUTO_SSO_ENABLED`, both in
`bulwark/app/helmrelease.yaml`):

- `OAUTH_ONLY=true` hides the password form (it can never authenticate anyway — the Stalwart directory is
  OIDC-only) and leaves just the SSO button; `OAUTH_PASSWORD_FALLBACK_ENABLED=true` would add a
  "sign in with password" link back.
- `AUTO_SSO_ENABLED=true` makes the login page start the SSO redirect on load. Its effect is guarded by a
  `sessionStorage` `sso_attempted` flag that clears after 30 s (so a broken IdP cannot loop), and it skips
  when `mode=add-account` is set or when the page is in a refused state — expect the _first_ visit in a
  fresh browser to show the button rather than redirect.

Verify the flags rather than the HTML (the SPA reads them from `/api/config`):

```sh
curl -sS https://webmail.480p.com/api/config | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print({k:v for k,v in d.items() if "oauth" in k or "sso" in k})'
```

### Applied configuration (2026-11)

The Directory object is `Oidc` with `issuerUrl: https://sso.brauni.dev/application/o/bulwark/`,
`acceptedAudiences: {bulwark: true}`, `claimUsername: preferred_username` + `usernameDomain: 480p.com`,
`claimName: name`, `claimGroups: groups`, `trustedProvider: true`, `unscopedTokens: full`, and
`Authentication.directoryId` points at it. Verified end to end: an authentik access token yields
`username: brauni@480p.com` from `/jmap/session` on all three pods, and both accounts keep
`roles: { "@type": "Admin" }` (roles live on the local Account record, not in the directory).

Driving it without the WebUI — the management API is JMAP (`urn:stalwart:jmap`) on the normal HTTP
listener, authenticated with an API key (`Authorization: Bearer API_...`, created in the WebUI under
Settings › Account › API keys; account `bernard` has one):

```sh
KEY=API_...; A=https://stalwart.480p.com
curl -sS -H "Authorization: Bearer $KEY" $A/jmap/session            # apiUrl + account id
curl -sS -X POST $A/jmap/ -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{
  "using":["urn:stalwart:jmap"],"methodCalls":
    [["x:Directory/get",{},"c1"],["x:Authentication/get",{"ids":["singleton"]},"c2"]]}'
```

`GET /api/schema/<Object>` returns the whole field/form/enum catalogue (gzip; follow the 302 to the
hashed path) — that is how to look up a field or action name instead of fishing through the WebUI bundles.

Two traps that cost time:

- **`ReloadSettings` is per instance.** It is not a `x:.../create`: the action is a JMAP _set_ on the
  singleton `x:Action`, i.e. `x:Action/set` with
  `{"create":{"a1":{"@type":"ReloadSettings"}}}` (result: `created.a1.warnings`, empty when clean).
  It reloads **only the pod that handled the call**, so after enabling the directory the Service keeps
  answering `401` about two times out of three — the fix is to reload each replica, e.g.
  `kubectl -n stalwart port-forward pod/stalwart-<n> 1820<n>:8080` and POST the action (then check
  `/jmap/session` with a real token against that port). A rolling restart does the same thing.

### WebUI sign-in (the `oauthClientId` half)

The webmail only needs the directory; the **WebUI additionally needs a client id it can hard-code**. Its SPA
prefers a Client ID Metadata Document (`https://stalwart.480p.com/admin/oauth-client.json`, optionally
`/account/oauth-client.json`) and reads the static id from `<meta name="oauth-client-id" content="…">` in the
served HTML. authentik cannot host CIMD, so without a static id the sign-in page answers
_Sign-in is not configured: the identity provider does not support client metadata documents and no OAuth
client id is configured for this application_.

Both halves are required **and they must be the same authentik client as the webmail**: Stalwart (Community)
has exactly one default directory, so it validates `iss` against **one** `issuerUrl`, while authentik derives the
issuer from the **application slug** (`/application/o/<slug>/`). Two clients = two issuers = one of them is
always rejected. Concretely, with a separate `stalwart-webui` provider the WebUI completed the flow, authentik
minted tokens (iss `/o/stalwart/`), and Stalwart answered `401` because the directory trusts `/o/bulwark/` —
no `auth.success` in the Stalwart log, no error either. That dead end is why `stalwart-webui-oidc.yaml` was
retired (`stalwart-webui-retired.yaml`, `state: absent`) and the WebUI now reuses the `bulwark` client:

1. authentik `bulwark-oidc.yaml`: **public** client (PKCE, no secret — the WebUI can only do
   `token_endpoint_auth_method: none`), carrying the webmail's regex callback **plus** the WebUI's four
   strict ones (`https://stalwart.480p.com/{admin,account}/oauth/callback` and the `mail.480p.com` twins).
1. Stalwart: that one client id in two places — the directory's `acceptedAudiences` (authentik puts the client
   id in `aud`; the check is not relaxed) **and** `x:Application.oauthClientId` (id `jqczdn3qaaab`, the
   "Stalwart Web Interface" app).
1. Bulwark itself stays unaffected: it sends `client_secret` only when `OAUTH_CLIENT_SECRET` is set
   (`g && f.set("client_secret", g)`), so it drops to PKCE-only once the secret is gone; authentik ignores a
   secret sent by a public client anyway (`invalid_grant`, not `invalid_client`, so the switch has no window).

**The meta tag is baked in at pod start, not on `ReloadSettings`.** After setting `oauthClientId` every pod
kept serving `content=""` (the zip ships the placeholders empty; the server rewrites them when it unpacks the
bundle at boot). `UpdateApps` did not help; deleting each `stalwart-<n>` pod one at a time did. So the order
that works is: set the objects → reload settings → restart the pods → verify with

```sh
curl -sS https://stalwart.480p.com/admin/ | grep -o 'oauth-client-id" content="[^"]*"'
curl -sS 'https://stalwart.480p.com/api/discover/brauni%40480p.com'   # the IdP metadata the SPA uses
```

`/api/discover/<username>` is also the fastest way to check which issuer a given account resolves to: it
returns the IdP's endpoints for the domain the directory serves, plus `stalwart_required_scopes`. Compare the
`issuer` field there with the `iss` of the token the app actually sends — a mismatch is the silent-401 case
above.

**It also needs `offline_access`, or the session expires the moment it starts.** The SPA asks for exactly
the scopes in that document's `stalwart_required_scopes` (Stalwart derives it: `openid` plus whatever the
username/name claims need, so `openid profile`) — it never adds `offline_access` on its own, and Stalwart
strips `offline_access` from the proxied `scopes_supported`. authentik only mints a refresh token when the
_granted_ scopes contain `offline_access`, so the token response has none, and the SPA's token-refresh path
is unconditional on it:

```js
async function refresh(){ const {refreshToken, tokenEndpoint, clientId} = state();
  if (!refreshToken || !tokenEndpoint || !clientId) throw expireSession();  // → "Your session has expired"
```

The symptom is a sign-in loop: authentik logs `authorize_application` with `scope: "openid profile"`, the
`/admin/oauth/callback?code=…` request arrives and **3 access tokens are minted**, yet Stalwart logs no
`auth.success` at all (the WebUI never sends the token) and the browser lands back on `/admin/login` with
_session expired_. Fix: put the missing scope on the Application so the server injects it into
`<meta name="oauth-scopes">`, then restart the pods (same boot-time meta as above):

```sh
x:Application/set  {"update":{"jqczdn3qaaab":{"oauthScopes":{"offline_access":true}}}}
curl -sS https://stalwart.480p.com/admin/ | grep -o 'oauth-scopes" content="[^"]*"'   # offline_access
```

**`claimGroups: groups` provisions local groups** named after authentik groups (`Media`, `Platform`,
`Silo`, `Mail`) on the first successful token, with `roles: Default`, and puts the account in them. They
grant nothing on their own (Stalwart roles are still per-Account), but it is noise if you expected the
account list to stay clean — drop `claimGroups` if the mirroring is not wanted.

## Proxmox side (not in this repo)

Inbound mail ports are **DROPped by `pve-firewall` today** (`cluster.fw`, `policy_in: DROP`; only SSH and
a few exporter ports are open) and nothing DNATs. On each host, parameterised:

```
nft add rule ip nat PREROUTING iifname "<WAN_IF>" ip daddr <PVE_PUB> tcp dport {25,465,587,993,4190,443} dnat to <LOCAL_WORKER_IP>:<nodeport>
nft add rule ip nat POSTROUTING ip saddr <LOCAL_WORKER_IP> oifname "<WAN_IF>" snat to <PVE_PUB>
```

plus a `cluster.fw` accept for FORWARDed traffic (DNAT to a VM traverses FORWARD, not INPUT);
`nf_conntrack_allow_invalid: 1` is already set on all three hosts. The hosts are byte-identical in
`cluster.fw`, `host.fw`, listeners and package sets - keep it that way; `ovhsbg1` currently trails one
kernel behind (7.0.14-28 vs -29), unrelated to mail but a bad A/B baseline.

PTR per public IP must point at `mail.<domain>`, and every A record must stay **grey-cloud** in
Cloudflare: `external-dns` runs with `--cloudflare-proxied` and cannot emit unproxied records.

## Known gaps

- Dragonfly is not a supported store (see above). The cluster is a lab until the checks in
  "Verifying the store actually works across nodes" pass repeatedly.
- The store is a single pod with PVC snapshots, not a quorum: restart is a brief outage, and a full store loss
  means empty locks/counters, which is recoverable-but-visible (retries, re-greylisting).
- No PDB (3 pods on 3 nodes leaves no slack during a worker drain), no antivirus (Stalwart has none
  built in - Rspamd/ClamAV is a separate decision).
- Inbound capacity drops by a third when a worker is cordoned, until DNS steering reacts.
- HTTP/443 is DNATed for JMAP/DAV; keeping it public vs moving it behind the Cloudflare tunnel is still
  an open decision.
