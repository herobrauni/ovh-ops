# Networking: external-dns, Envoy Gateway, tailnet — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when touching DNS records,
Gateway/Envoy tuning, or tailnet-only exposure.

## external-dns — never go back to `--annotation-filter`

- external-dns v0.22.0 (chart 1.22.0) broke `--annotation-filter` on the CRD source: the filter is parsed via `metav1.ParseToLabelSelector` (`source/annotations/processors.go`) which rejects set-based selectors, the error is discarded in `NewSourceConfig`, and the resulting selector matches **nothing** in the informer transform — every DNSEndpoint is dropped from the cache. With `policy: sync` the very first sync after the upgrade mass-**deleted** every owned record in the Cloudflare zones `480p.com` (all records) and `brauni.dev` (all external-dns records); `riki.boo` survived only because its records were still owned under the older `k8s.cname-*` TXT prefix.
- The split-horizon scoping therefore uses `--label-filter=dns.scope in (...)` plus a `dns.scope` **label** on every DNSEndpoint (mirroring the annotation; `--label-filter` goes through the real `labels.Parse` and works — see `kubernetes/components/dnsendpoint`).
- Until upstream fixes annotation-filter parsing on the CRD source, do NOT switch these HelmReleases back to `--annotation-filter`, and treat any external-dns upgrade as potentially record-deleting: verify sources with a `--dry-run --once` one-off pod (`kubectl run` with the same args) before letting a new version reconcile.
- Leftover unowned `k8s.cname-*` TXT records plus their unowned CNAMEs still exist in `riki.boo` and are skipped by the `ovh-ops.`-prefixed instance (cosmetic; clean up by deleting them and letting external-dns recreate owned copies).

## Envoy Gateway tuning

- Timeout/keepalive tuning lives in `network/envoy-gateway/common/envoy.yaml` (ported from onedr0p's final state after his three 2026-09-14 iterations — do not resurrect the 30s/60s/120s intermediates): BackendTrafficPolicy `tcpKeepalive {idleTime 60s, interval 10s, probes 3}` + `connectionIdleTimeout 4s` + `streamIdleTimeout 1h` + `requestTimeout 0s` at Gateway scope; ClientTrafficPolicy same keepalive + `idleTimeout: 600s`.
- The downstream (CTP) idle timeout must stay well **above** the cloudflared keep-alive interval or tunnels reset mid-stream — that constraint is why the earlier 60s/120s values were wrong. His `connection.bufferLimit: 4Mi` was deliberately dropped again in the final tuning; do not re-add it blindly.
- Route-level BTPs override the 4s upstream idle close per app (see plex).

## plex HTTPRoute / BackendTrafficPolicies

- The plex HTTPRoute (`media/plex`) uses named rules with `X-Plex-Http-Pipeline: infinite` set on **every** rule — PMS closes idle keep-alive connections after 20s otherwise, so Envoy must own the upstream pool — plus two route-level BackendTrafficPolicies: `plex` adds `requestBuffer 1Mi` + `connectionIdleTimeout 300s`, while `plex-events` (targetRef `sectionName: events`) re-sets the same timeout **without** requestBuffer because request buffering hangs WebSocket upgrades (`/:/eventsource`, `/:/websockets`).
- Rule order is most-specific-first (`subtitles` → `events` → `app` catch-all): Gateway API matching is first-match-wins and a rule with no matches matches everything, so a catch-all rule first would shadow the specific ones — keep the corrected order.

## Multi-domain routes

- Multi-domain auth (e.g. `echo` on `480p.com`/`brauni.dev`/`riki.boo`) uses separate `HTTPRoute` objects per hostname/domain with a matching `SecurityPolicy` per route (and one Authentik provider per hostname) — do not assume a single generated route can be targeted per-host with `sectionName`; follow `kubernetes/apps/network/echo/app/httproute.yaml` + `securitypolicy.yaml`. See `docs/agents/authentik.md`.

## Tailnet-only apps

- Tailnet-only apps intentionally skip the "App Exposure Rule" (`DNSEndpoint` + Homepage annotations): they get their name from MagicDNS and have no public route to annotate. Layer 3 uses `spec.type: LoadBalancer` + `spec.loadBalancerClass: tailscale` on the Service (app-template v5 templates all three fields); layer 7 uses a standalone Ingress with `ingressClassName: tailscale` and `spec.tls[].hosts`.
- `observability/holmesgpt` (`app/ingress.yaml`) is the layer-7 reference: the `spec.tls[].hosts[0]` value becomes the MagicDNS name (`https://<host>.<tailnet>.ts.net`) and the operator provisions the Let's Encrypt cert itself — no HTTPRoute, DNSEndpoint or Homepage annotations involved. It needs MagicDNS + HTTPS certificates enabled in the tailnet admin console, otherwise the ingress proxy pod never gets an ADDRESS.
- The cluster pod network is IPv4-only (relevant for guests: `docs/agents/kubevirt-vms.md`).
