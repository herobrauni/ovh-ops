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
