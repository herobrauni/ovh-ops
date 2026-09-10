# Authentik forward auth for apps behind Envoy Gateway

Runbook for replacing TinyAuth with Authentik's **embedded outpost** as the Envoy Gateway
`extAuth` provider. Written when `sonarr.480p.com` / `radarr.480p.com` were migrated
(2026-09-10); use it as the template for the remaining 480p.com apps (`sonarr4k`, `radarr4k`, …).

Two halves, and they live in different places:

| Half                                                                     | Where it lives                          |
| ------------------------------------------------------------------------ | --------------------------------------- |
| Envoy `SecurityPolicy`, outpost `HTTPRoute`, Gatus annotations, `ks.yaml` | Git (`kubernetes/apps/<ns>/<app>/`)     |
| Group, ProxyProvider, Application, PolicyBinding                          | Authentik DB — **created by hand**, not in Git (see [Authentik-side state](#authentik-side-state-not-in-git)) |

## Request flow

```text
browser ─▶ Envoy (10.10.8.15, *.480p.com) ─▶ extAuth ─▶ authentik-server:80
                                                    │            /outpost.goauthentik.io/auth/envoy
   ①  302 ──▶ https://sso.brauni.dev/application/o/authorize/?client_id=<provider>&…
   ②  302 ──▶ https://<app>.480p.com/outpost.goauthentik.io/callback?code=…   (unauthenticated HTTPRoute → authentik-server)
   ③  302 ──▶ //<app>.480p.com/  + Set-Cookie: authentik_proxy_<hash>
   ④  200 ──▶ Envoy ─▶ app, with X-authentik-* identity headers
```

Key consequences:

- The outpost is **in-process inside `authentik-server`** — there is no `ak-outpost-*` Service.
  `backendRefs` always point at Service `authentik-server`, ns `authentik`, port **80** (container 9000).
- The 2026.8 outpost is **OIDC-based**: the old `/outpost.goauthentik.io/start` flow is gone, and
  the OIDC callback is served **on the app hostname**. Step ② only works if a separate HTTPRoute
  routes `/outpost.goauthentik.io` on the app host to `authentik-server`.
- Provider matching is by `Host`, so the original `:authority` must reach the ext-auth request
  (Envoy Gateway does this by default).

## Why one provider per app (`forward_single`)

`forward_single` + empty `cookie_domain` gives a host-only `authentik_proxy_<hash>` cookie **per app**.
A domain-wide `forward_domain` provider would need `cookie_domain: .480p.com`, and no cookie can span
`brauni.dev` / `riki.boo` / `480p.com` (different registrable domains). Per-app sessions are therefore
expected — but users only log in once, because every provider reuses the **shared `sso.brauni.dev`
login session**, so the second app is a silent redirect through the authorize endpoint.

## Step 1 — Authentik objects

Run inside the server pod; everything below is idempotent-ish Python.

```bash
kubectl exec -n authentik deploy/authentik-server -c server -- ak shell -c '<script>'
```

### 1a. Group for access control (once, already exists: `Media`)

```python
from authentik.core.models import Group
Group.objects.get_or_create(name="Media", defaults={"is_superuser": False})
```

### 1b. Provider + Application + binding

```python
from authentik.core.models import Application, Group
from authentik.flows.models import Flow
from authentik.outposts.models import Outpost
from authentik.policies.models import PolicyBinding
from authentik.providers.proxy.models import ProxyProvider

SLUG, NAME, HOST = "prowlarr", "Prowlarr", "https://prowlarr.480p.com"

provider = ProxyProvider.objects.create(
    name=NAME,
    authorization_flow=Flow.objects.get(slug="default-provider-authorization-implicit-consent"),
    invalidation_flow=Flow.objects.get(slug="default-provider-invalidation-flow"),
    mode="forward_single",
    external_host=HOST,
    skip_path_regex="^/ping$",  # keeps the Gatus liveness probe unauthenticated (step 4)
)
provider.set_oauth_defaults()  # REQUIRED for a raw ORM create — see gotchas
provider.save()
Outpost.objects.get(name="authentik Embedded Outpost").providers.add(provider)

application = Application.objects.create(name=NAME, slug=SLUG, provider=provider)
PolicyBinding.objects.create(  # order/negate/enabled/failure_result: see gotchas
    target=application, group=Group.objects.get(name="Media"),
    order=0, negate=False, enabled=True, failure_result=False,
)
print("client_id:", provider.client_id)
```

### 1c. Users

Create accounts in the UI (`Directory → Users`). Only group membership matters for access:

```python
Group.objects.get(name="Media").users.add(User.objects.get(username="brauni"))
```

MFA enrollment is a user-side action in the UI (`/if/user/#/settings` → MFA Devices).

## Step 2 — Kubernetes manifests (Git)

Per app, in `kubernetes/apps/<namespace>/<app>/app/`:

**`securitypolicy.yaml`** — point `extAuth` at the outpost and pass the identity headers through:

```yaml
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <app>-480p-com
  extAuth:
    failOpen: false
    headersToExtAuth: [X-Forwarded-For, X-Forwarded-Host, X-Forwarded-Proto, X-Forwarded-Uri, accept, authorization, cookie, user-agent]
    http:
      backendRefs:
        - name: authentik-server
          namespace: authentik
          port: 80
      path: /outpost.goauthentik.io/auth/envoy
      headersToBackend: [Location, Set-Cookie, X-authentik-email, X-authentik-groups, X-authentik-name, X-authentik-uid, X-authentik-username]
```

**`httproute-outpost.yaml`** (new) — the OIDC callback must be served on the app host **without**
ext-auth, so it gets its own HTTPRoute. Reusing the app's HTTPRoute would make Envoy ext-auth the
callback and loop:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app>-480p-com-outpost
  annotations:
    gatus.home-operations.com/enabled: "false" # else the sidecar probes /outpost.goauthentik.io
spec:
  hostnames: ["<app>.480p.com"]
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

**`kustomization.yaml`** — add `./httproute-outpost.yaml`.

**`ks.yaml`** — depend on the Authentik Kustomization instead of TinyAuth:

```yaml
spec:
  dependsOn:
    - name: authentik
      namespace: authentik
```

**`httproute.yaml`** — keep the existing route (Homepage annotations stay), add the Gatus override
(step 4). TinyAuth's Kustomization, ReferenceGrant and secret stay deployed for the apps that have
not migrated; mix-and-match per route is fine.

## Step 3 — ReferenceGrant (once per consumer namespace)

Cross-namespace `backendRef` from `SecurityPolicy`/`HTTPRoute` in `<ns>` to Service
`authentik-server` in `authentik` needs a grant in the **target** namespace
(`kubernetes/apps/authentik/authentik/app/referencegrant.yaml`, currently scoped to `media`).
Add `from` entries for each namespace as apps migrate.

## Step 4 — Gatus

Three things, because the sidecar (`--auto-httproute`) derives endpoints from routes:

1. Provider `skip_path_regex` for the probe path, so it returns 200 without authentication.
   The outpost's skip check runs **before** basic-auth handling, so the inherited
   `Authorization: Basic …` header from the Gateway annotation is harmless (verified with and
   without it). Anonymous liveness paths found so far:

   | App | Path | Notes |
   | --- | --- | --- |
   | `*arr` apps (sonarr, radarr, prowlarr, incl. 4K) | `/ping` | `[AllowAnonymous]`, returns `{"status":"OK"}` |
   | altmount | `/health` | `/healthz` also answers; the app's `/sabnzbd` and `/webdav` routes are separate HTTPRoutes |
   | clonarr | `/api/health` | `/ping`, `/health`, `/healthz` are 404 |
   | umlautadaptarrex | `/api/health` | on the routed port 5007 (`/ping`, `/health` are 404 there) |

   To find one for a new app, probe the Service from a throwaway pod first:

   ```bash
   kubectl run probe -n observability --image=curlimages/curl:8.11.1 --restart=Never --rm -i \
     --command -- sh -c 'for p in / /health /healthz /api/health /ping; do
       printf "%-16s " "$p"; curl -s -o /dev/null -w "%{http_code}\n" -m 5 \
         "http://<app>.media.svc.cluster.local:<port>$p"; done'
   ```

   An in-cluster 200 is a **candidate, not proof**: the app may exempt local addresses, and the
   outpost may skip a path while the app still answers 401/302. Prove it through the gateway
   without credentials after the migration. If the app has no anonymous path, assert its own auth
   challenge instead of 200
   (`gatus.home-operations.com/endpoint: |- conditions: ["[STATUS] == 401"]`, as altmount's
   `/webdav` route does) or disable the endpoint entirely. **Never** leave a probe on `/` behind
   Authentik: an unauthenticated request gets a 302 and the endpoint reports failed.

   Watch for **extra routes on the same hostname** (altmount: `/sabnzbd`, `/webdav`): each is a
   separate HTTPRoute, may deliberately bypass ext-auth, and gets its own sidecar-generated
   endpoint that otherwise inherits an `== 200` condition that does not fit.
2. On the app's HTTPRoute, override the probed URL:
   `gatus.home-operations.com/endpoint: |- url: https://<app>.480p.com/<liveness-path>`
   (conditions/group/interval/headers are inherited from the `envoy-480p-com-public` Gateway).
3. On the outpost HTTPRoute, `gatus.home-operations.com/enabled: "false"`, otherwise the sidecar
   emits a second endpoint for `https://<app>.480p.com/outpost.goauthentik.io` that fails.

## Step 5 — Verification

`--resolve` gives a genuine end-to-end test (real TLS, HTTPRoute, ext-auth) without touching DNS.
`10.10.8.15` is the `envoy-480p-com-public` LoadBalancer IP.

```bash
# 1. unauthenticated: expect 302 to sso.brauni.dev
curl -sS -o /dev/null -w '%{http_code} -> %{redirect_url}\n' --resolve <app>.480p.com:443:10.10.8.15 https://<app>.480p.com/

# 2. liveness path: expect 200 {"status": "OK"}
curl -sS --resolve <app>.480p.com:443:10.10.8.15 https://<app>.480p.com/ping

# 3. full authenticated flow: expect 200 <title>Sonarr</title>
```

For an authenticated test, forge a session (authentik signs the session cookie, so a bare session
key is rejected — the cookie value is `SessionMiddleware.encode_session()`):

```bash
JWT=$(kubectl exec -n authentik deploy/authentik-server -c server -- ak shell -c "
from django.contrib.auth import login
from django.test import RequestFactory
from authentik.core.models import User
from authentik.core.sessions import SessionStore
from authentik.root.middleware import SessionMiddleware
u = User.objects.get(username='brauni')
r = RequestFactory().get('/', HTTP_USER_AGENT='curl-e2e-test')
r.session = SessionStore(); login(r, u, backend='authentik.stages.password.stage.backend'); r.session.save()
print('MARKJWT', SessionMiddleware.encode_session(r.session.session_key, u))" 2>&1 | awk '/^MARKJWT/{print $2}')

printf '# Netscape HTTP Cookie File\nsso.brauni.dev\tFALSE\t/\tTRUE\t0\tauthentik_session\t%s\n' "$JWT" > /tmp/jar.txt
curl -sS -L -D /tmp/h -o /tmp/b -b /tmp/jar.txt -c /tmp/jar.txt \
    --resolve <app>.480p.com:443:10.10.8.15 -w 'FINAL %{http_code}\n' https://<app>.480p.com/
grep -Ei '^(HTTP/|location:)' /tmp/h
```

Expected chain: `302 → sso.brauni.dev/application/o/authorize/…` → `302 → https://<app>.480p.com/outpost.goauthentik.io/callback…`
→ `302 → //<app>.480p.com/` (+ `authentik_proxy_<hash>` cookie) → `200 <title>Sonarr</title>`.

Gotcha that cost an hour: **do not pass the cookie with `-H "Cookie: …"`** — curl does not carry a
hand-set `Cookie` header across redirects, so the authorize request arrives unauthenticated and the
flow silently degrades into the login form. Put it in the cookie jar instead.

Negative test: repeat with a user that is **not** in the group → must land on Authentik's
"Request has been denied" page. Remember to delete forged sessions afterwards: take the `sid`
claim from the JWT you minted and `SessionStore(session_key=<sid>).delete()`;
`django.contrib.sessions.models.Session.objects.all()` should then be empty.

## Rollback

One squash commit per app ⇒ `git revert <merge-commit>`. TinyAuth stays deployed and its
ReferenceGrant already covers `media`, so a revert restores the previous behaviour immediately.
The Authentik-side objects are harmless if left behind.

## Gotchas

- **`set_oauth_defaults()`**: a raw ORM `create()`/`save()` does *not* populate `grant_types`,
  callback `redirect_uris` and the "Proxy outpost" scope mapping — the API/UI serializer does.
  Without it the provider is incomplete and login fails. Same for later edits: assign the field,
  then `set_oauth_defaults()` + `save()` if you touched anything OAuth-related.
- **Consent**: use `default-provider-authorization-implicit-consent` for forward auth; explicit
  consent adds a click-through page users cannot skip.
- **Access control is separate from authentication**: `core_default_app_access=True` keeps an
  application open *only while it has zero bindings*. Adding a binding (here: Group `Media`) locks
  out every other authenticated user, and `PolicyAccessView.user_has_access()` has **no superuser
  bypass** — `akadmin` is denied too until it joins the group.
- **Protocol-relative post-login redirect** (`//<app>.480p.com/`, goauthentik/authentik#19653,
  closed as not planned). Desktop browsers and curl resolve it correctly; mobile Chrome/Brave have
  been reported to mishandle it. Nothing to fix in this repo.
- **Keep the outpost HTTPRoute separate** and its Gatus annotation disabled (see steps 2 and 4).
- **`skip_path_regex` is app-wide**: `^/ping$` exposes the liveness endpoint unauthenticated.
  That is intended for Gatus; do not widen it to paths that leak data.
- Authentik reference: `authorization_flow` / `invalidation_flow` slugs, provider `client_id`
  (`YF4X9tBQ…` for Sonarr) are stable; new providers get fresh client IDs, which is fine because
  the outpost is configured through the provider itself.

## Authentik-side state (not in Git)

Created by hand for the Sonarr/Radarr cutover — a blueprint could bring this into Git later:

- Group `Media` (no roles, `is_superuser: false`), member `brauni`.
- ProxyProvider `Sonarr` (`forward_single`, `https://sonarr.480p.com`, `skip_path_regex: ^/ping$`)
  and `Radarr`; both assigned to `authentik Embedded Outpost`.
- Applications `Sonarr` (slug `sonarr`) and `Radarr` (slug `radarr`), one `PolicyBinding` each
  → Group `Media`, allow, order 0.
- Same again for `Sonarr 4K` (`sonarr4k`) and `Radarr 4K` (`radarr4k`).
- `AltMount` (`altmount`, `skip_path_regex: ^/health$`), `Clonarr` (`clonarr`, `^/api/health$`),
  `Prowlarr` (`prowlarr`, `^/ping$`) and `UmlautAdaptarrEX` (`umlautadaptarrex`, `^/api/health$`):
  `forward_single`, one application each, one `PolicyBinding` → Group `Media`, embedded outpost.
- Users `brauni` (in `Media`) and `authentik_testuser1` (in no group — the negative-test account).
