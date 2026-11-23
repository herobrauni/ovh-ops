# Stalwart mail cluster — topology, bootstrap, traps

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when touching
`kubernetes/apps/stalwart/`.

Stalwart v1 is a single binary with mail data in shared stores. This namespace runs it as an
active-active cluster: three `stalwart` pods (one per worker), `Stalwart Keep` as in-memory store and
coordinator, `postgres18` for the data store, Ceph RGW (S3) for blobs.

## Topology and why it looks like this

```
                 MX/A: three grey-cloud records, one per PVE host
   PVE1 54.38.92.92        PVE2 54.38.94.158        PVE3 54.38.94.150
        nft DNAT                nft DNAT                nft DNAT
           v                        v                        v
   w-ovhsbg1 :30025/30587/30465/30993/30419/30443   (NodePorts, ETP Local)
        v                        v                        v
   stalwart-0                stalwart-1                stalwart-2
                     Postgres + RGW S3 + Keep
```

- **One public IP per PVE host already exists** (`vmbr0` on each host), and each worker already
  egresses through its _own_ host: `w-ovhsbg1 -> .92.92`, `w-ovhsbg2 -> .94.158`, `w-ovhsbg3 -> .94.150`
  (verified with pinned probe pods). That is the property 1:1 DNAT depends on — keep it that way, and
  never point a worker's default route at another host's gateway.
- `externalTrafficPolicy: Local` on `stalwart-mail` is load-bearing: the public IP that accepted a
  connection must also be the one that sends the reply, so Cilium must never forward the connection to
  another node. Consequence: if `stalwart-<i>` is down, `<PVE_i>:25` refuses and senders retry against
  the other two IPs. There is no floating IP and no BGP; steering is DNS only.
- Proxmox HA live migration **must not move the three worker VMs** (they are HA resources, `vm:184-186`).
  Moving a worker desynchronises the worker↔IP mapping. If a worker must be evacuated, remove its IP
  from DNS first.

## Keep (in-memory store + coordinator)

Upstream's recommended store, and the reason this namespace is `privileged` PSS. Traps that are easy to
get wrong:

- **`members` holds IP literals**, so each ordinal is pinned to a node by a 1Mi hostPath PV
  (`persistentvolumes.yaml`, `claimRef: pin-keep-<i>`). Do not "simplify" this to `nodeAffinity` on the
  pod: one template cannot pin per ordinal, and two ordinals swapping nodes breaks the member list.
- **Shards must equal the container CPU limit** (`2` in `keep.toml` ↔ `limits.cpu: 2`). Changing the
  limit without changing the member list is a misconfiguration, not a resize.
- **`terminationGracePeriodSeconds: 30`** (upstream minimum 16 = 1 s freeze + up to 11 s handoff).
  Lowering it drops keys during handoff.
- **`podManagementPolicy: Parallel` is mandatory** — a member stays fenced until a majority of the list
  runs, so `OrderedReady` deadlocks on the first pod.
- **The ConfigMap is immutable and versioned** (`keep-config-1`); Keep reads it only at start. A member
  list change means a new ConfigMap _and_ switching the readiness probe from the `ready-file` to a TCP
  check on 7000 — otherwise the rollout blocks forever, because the first restarted members cannot
  settle against the new list.
- **`--start` must never be set to `bootstrap`** in the template. First start of a brand-new cluster
  therefore refuses new locks for ~10 min (lock quarantine).
- **Peer port 7100 leaks.** Upstream requires it reachable only from members; NetworkPolicy is
  undefined for hostNetwork pods. Here 7100 is reachable from every VM on the `10.10.8.0/24` bridge
  (`ovh-hermes1`, `ovh-dns1`, `pve-immich`, …) and over `tailscale0`. Accepted gap for now; closing it
  needs a Talos ingress firewall rule scoped to the three worker IPs, not a k8s resource.
- Keep has **no persistence**: a full cluster restart starts empty. That is by design (locks, counters,
  greylisting), but it means "restart all of Keep" is a visible 10-minute event, not a no-op.

## Secrets (all under Infisical `/stalwart/`)

| Key                                                     | What                                                                     |
| ------------------------------------------------------- | ------------------------------------------------------------------------ |
| `KEEP_CLUSTER_SECRET`, `KEEP_PEER_SECRET`               | `openssl rand -hex 16` each                                              |
| `KEEP_SERVERS_PEM_B64`                                  | public keys of all three members, base64 (so newlines survive Infisical) |
| `KEEP_CLIENTS_PEM_B64`                                  | public key of the Stalwart client identity, base64                       |
| `KEEP_MEMBER{0,1,2}_KEY_B64`                            | each member's Ed25519 private key, base64                                |
| `STALWART_CLIENT_KEY_B64`                               | private key for the (shared) Stalwart client identity, base64            |
| `STALWART_RECOVERY_ADMIN_USER` / `_PASSWORD`            | bootstrap administrator — delete after first login                       |
| `/cloudnative-pg/stalwart_postgres_{username,password}` | created by hand, consumed by `components/cnpg`                           |

Generation (Keep defaults to mutual TLS 1.3 with raw public keys, so keys are not optional):

```sh
# per member i
openssl genpkey -algorithm ed25519 -out keep-$i.key
openssl pkey -in keep-$i.key -pubout -out keep-$i.pub
# client identity used by all three Stalwart nodes
openssl genpkey -algorithm ed25519 -out client.key
openssl pkey -in client.key -pubout -out client.pub
cat keep-0.pub keep-1.pub keep-2.pub > servers.pem
cp client.pub clients.pem
base64 -w0 keep-$i.key   # -> KEEP_MEMBER${i}_KEY_B64
```

`STALWART_CLIENT_KEY_B64` is shared by all three nodes on purpose: per-node identities would need a
per-pod secret source, and the coordinator holds nothing durable.

## Bootstrap (the only part that is not declarative)

Ordering is enforced by the server, not by us: the store/coordinator settings live in Postgres, and a
coordinator is rejected while the in-memory store is still the local default.

1. Create the Infisical secrets above **and** `/cloudnative-pg/stalwart_postgres_username`
   (`stalwart`) + `_password`. Without them the ExternalSecrets sit in `SecretSyncedError` and nothing
   starts.
2. Let Flux apply. `stalwart-0` starts with `replicas: 1` and `STALWART_RECOVERY_ADMIN` set. Confirm
   `/healthz/ready` is 200 and `keep-0..2` are Ready.
3. `kubectl -n stalwart port-forward svc/stalwart-mgmt 8080:8080`, sign in as the recovery admin.
4. Create a permanent administrator account + API key; sign in with it.
5. Set, in this exact order, verifying each one applies:
    - **Blob Store**: S3, region `us-east-1`, bucket `${STALWART_S3_BUCKET}`, endpoint `${STALWART_S3_URL}`,
      access/secret via `EnvironmentVariable` refs `STALWART_S3_ACCESS_KEY` / `STALWART_S3_SECRET_KEY`
      (they are already in the pod env — never paste the keys into the WebUI).
    - **Search Store**: the shared Postgres data store.
    - **In-Memory Store**: Keep, `keep://10.10.8.182:7000,10.10.8.184:7000,10.10.8.186:7000` with
      `secret=` `KEEP_CLUSTER_SECRET`, `cluster=on`, `tls=rpk`, `key=/etc/keep-client/client.key`,
      `servers=/etc/keep-client/servers.pem`.
    - **Coordinator**: `Default` (reuses the Keep connection).
6. Restart `stalwart-0`, confirm it still reports ready and that logs show Keep + Postgres + S3 with no
   fallback to local stores. Then remove `STALWART_RECOVERY_ADMIN` from the ExternalSecret **and** flip
   `controllers.stalwart.replicas` to `3` in the same change.
7. Verify 3 pods on 3 distinct nodes (`kubectl -n stalwart get pods -o wide`), all three present in
   _Settings › Cluster_, then run the cross-node check: connect IMAP to each public IP and confirm the
   same mailbox state.

A same-node restart is the routine event; a pod that lands on a different node rewrites nothing except
its node id.

## Proxmox side (not in this repo)

Inbound mail ports are **DROPped by `pve-firewall` today** (`cluster.fw`, `policy_in: DROP`, only SSH and
a few exporter ports are open), and nothing DNATs. On each host, parameterised:

```
nft add rule ip nat PREROUTING iifname "<WAN_IF>" ip daddr <PVE_PUB> tcp dport {25,465,587,993,4190,443} dnat to <LOCAL_WORKER_IP>:<nodeport>
nft add rule ip nat POSTROUTING ip saddr <LOCAL_WORKER_IP> oifname "<WAN_IF>" snat to <PVE_PUB>
```

plus a `cluster.fw` accept for FORWARDed traffic (DNAT to a VM traverses FORWARD, not INPUT) and
`nf_conntrack_allow_invalid: 1` (already set on all three hosts). The three hosts are byte-identical in
`cluster.fw`, `host.fw`, listeners and packages — keep it that way; `ovhsbg1` currently trails one kernel
(7.0.14-28 vs -29), which is unrelated to mail but makes it a bad baseline for A/B testing.

PTR per public IP must point at `mail.<domain>`, and every A record must stay **grey-cloud** in
Cloudflare — `external-dns` runs with `--cloudflare-proxied`, so these records cannot be managed by it.

## Known gaps

- No storage of in-flight queue state beyond Postgres, no PDB (3 pods on 3 nodes leaves no slack during a
  drain), no antivirus (Stalwart has none built in — Rspamd/ClamAV integration is a separate decision).
- `replicas: 3` plus required anti-affinity means a cordoned worker takes one third of inbound capacity
  out of service until DNS steering reacts.
- HTTP/443 is DNATed for JMAP/DAV; whether that stays public or moves behind the Cloudflare tunnel is
  still open.
