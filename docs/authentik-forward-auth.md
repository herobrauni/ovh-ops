# Authentik forward auth for apps behind Envoy Gateway

Runbook for replacing TinyAuth with Authentik's **embedded outpost** as the Envoy Gateway
`extAuth` provider. Written when `sonarr.480p.com` / `radarr.480p.com` were migrated
(2026-09-10); use it as the template for the next app. Migrated so far: the media set
(`sonarr`, `radarr`, both 4K, `altmount`, `clonarr`, `prowlarr`, `umlautadaptarrex`) and the
platform/observability set (`echo` on all three domains, `flux-operator`, `konflate`,
`grafana`, `prometheus`, `alertmanager`, `victoria-logs`, `kopia`). TinyAuth is still
deployed and still fronts `vaultwarden.brauni.dev/admin`.

Two halves, and both live in Git:

| Half | Where it lives |
| --- | --- |
| Envoy `SecurityPolicy`, outpost `HTTPRoute`, Gatus annotations, `ks.yaml` | Git (`kubernetes/apps/<ns>/<app>/`) |
| Group, ProxyProvider, Application, PolicyBinding, outpost assignment | Git — blueprint `kubernetes/apps/authentik/authentik/app/blueprints/forward-auth.yaml` (see [step 1](#step-1--authentik-objects-git-the-forward-auth-blueprint)) |

Until 2026-09-11 those Authentik objects were created by hand through the API/UI; they are now
declared in that blueprint and re-applied from Git.

## Request flow

```text
browser ─▶ Envoy (*.480p.com 10.10.8.15 / *.brauni.dev 10.10.8.16 / *.riki.boo 10.10.8.13)
                ─▶ extAuth ─▶ authentik-server:80
                                     /outpost.goauthentik.io/auth/envoy
   ①  302 ──▶ https://sso.brauni.dev/application/o/authorize/?client_id=<provider>&…
   ②  302 ──▶ https://<app>.<domain>/outpost.goauthentik.io/callback?code=…   (unauthenticated HTTPRoute → authentik-server)
   ③  302 ──▶ //<app>.<domain>/  + Set-Cookie: authentik_proxy_<hash>
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

## Step 1 — Authentik objects (Git: the forward-auth blueprint)

Every Authentik-side object is declared in **one** blueprint file:

```text
kubernetes/apps/authentik/authentik/app/blueprints/forward-auth.yaml
```

kustomize turns it into the `authentik-blueprints` ConfigMap and the chart mounts that at
`/blueprints/custom` in **both** the server and the worker (`global.volumes` / `global.volumeMounts`
in `helmrelease.yaml`). The worker owns the file watcher (`BlueprintWatcherMiddleware`) and applies a
changed file right away; on top of that the `blueprints_discovery` schedule re-scans hourly at `:26`
with `send_on_startup: true`, so a pod restart is always enough to pick the file up. Blueprint state
is visible as `BlueprintInstance` **database** rows (there is no `BlueprintInstance` CRD, so
`kubectl get blueprintinstance` does not exist):

```bash
kubectl -n authentik exec deploy/authentik-server -c server -- ak shell -c "
from authentik.blueprints.models import BlueprintInstance
b = BlueprintInstance.objects.get(path='custom/forward-auth.yaml')
print('MARKBP', b.name, b.status, b.last_applied, b.last_applied_hash[:12])"
# MARKBP ovh-ops - Forward Auth successful 2026-09-11 12:38:52.078505+00:00 53819193f31c
kubectl -n authentik logs deploy/authentik-worker | grep -i blueprint
```

How to verify and recover an apply is in [1c](#1c-applying-verifying-and-re-applying).

### 1a. What the blueprint declares

- groups `Media` (media apps) and `Platform` (network / flux-system / observability / volsync).
- users `brauni` (member of both groups) and `authentik_testuser1` (member of none — the negative
  test account).
- reference-only `authentik_flows.flow` entries for
  `default-provider-authorization-implicit-consent` and `default-provider-invalidation-flow` with
  **no** attrs: the blueprint points at upstream flows, it does not own them.
- per hostname one `authentik_providers_proxy.proxyprovider` (`forward_single`,
  `cookie_domain: ""`, `external_host`, `skip_path_regex`), one `authentik_core.application`
  (provider → `!KeyOf` the provider) and one `authentik_policies.policybinding` (target → the
  application, group → `Media`/`Platform`, order 0 = allow).
- the embedded outpost's `providers` list.

### 1b. Adding a new app

Copy an existing block, change the identifiers, and add the provider to the outpost entry at the end
of the file:

```yaml
  - id: provider-prowlarr
    model: authentik_providers_proxy.proxyprovider
    identifiers:
      name: Prowlarr
    attrs:
      mode: forward_single
      cookie_domain: ""
      external_host: https://prowlarr.480p.com
      skip_path_regex: ^/ping$ # Gatus liveness path, see step 4
      authorization_flow: !KeyOf flow-authorization-implicit-consent
      invalidation_flow: !KeyOf flow-invalidation
  - id: app-prowlarr
    model: authentik_core.application
    identifiers:
      slug: prowlarr
    attrs:
      name: Prowlarr
      provider: !KeyOf provider-prowlarr
  - model: authentik_policies.policybinding
    identifiers:
      target: !KeyOf app-prowlarr
      group: !KeyOf group-media
      order: 0
```

…plus `- !KeyOf provider-prowlarr` under the outpost's `providers`. Then do the Kubernetes half
(steps 2–4) and merge; the worker applies the new state within seconds of the ConfigMap changing.

Validate before pushing: `Importer.validate()` really applies the file and then rolls the
transaction back, so a pass proves every reference resolves and no serializer rejects the payload
(it also means events and tasks are emitted and then discarded):

```bash
B64=$(base64 -w0 kubernetes/apps/authentik/authentik/app/blueprints/forward-auth.yaml)
kubectl -n authentik exec deploy/authentik-server -c server -- ak shell -c "
import base64
from authentik.blueprints.v1.importer import Importer
valid, logs = Importer.from_string(base64.b64decode('$B64').decode(), {}).validate()
print('MARKVALID', valid)
print('MARKBAD', [(l.log_level, l.event) for l in logs if l.log_level in ('warning', 'error')])"
```

`ak apply_blueprint <file> [--dry-run]` does the same from inside the pod.

### 1c. Applying, verifying and re-applying

A blueprint is applied by the **worker**: the file watcher applies a changed file right away, and
the hourly `blueprints_discovery` schedule (`:26`, `send_on_startup: true`) re-applies anything whose
content hash moved. `BlueprintInstance.last_applied_hash` is the sha512 of the file content, so the
cheap check is a local `sha512sum` against the row:

```bash
sha512sum kubernetes/apps/authentik/authentik/app/blueprints/forward-auth.yaml   # 53819193f31c…
```

To force an apply (after a failed run, or to convince yourself nothing is pending), use the very
same entry point as the UI's *Apply* button and the API action — an in-worker task:

```bash
kubectl -n authentik exec deploy/authentik-server -c server -- ak shell -c "
from authentik.blueprints.models import BlueprintInstance
from authentik.blueprints.v1.tasks import apply_blueprint
b = BlueprintInstance.objects.get(path='custom/forward-auth.yaml')
apply_blueprint.send_with_options(args=(b.pk,), rel_obj=b)
print('MARKQUEUED', b.pk)"
```

Equivalent: `POST /api/v3/blueprints/instances/<pk>/apply/` with an API token (the `pk` of that row),
or *System → Blueprints → Apply* in the UI. Applying an already-applied file is a no-op.

Two gotchas:

- **`successful` does not prove the change landed.** The first apply of this file finished
  `successful` with a matching `last_applied_hash` while `Sonarr`/`Radarr` still had
  `invalidation_flow: null` (everything else was applied). It ran while the worker was rolling
  through a stuck `Terminating` replica, and re-triggering it converged immediately. So when an
  expected diff is missing but the hash matches, just re-apply (recipe above) — and do **not**
  `kubectl rollout restart deploy/authentik-worker` while a first apply is in flight.
- **`default/flow-oobe.yaml` sits in `status: error`, and that is not your blueprint.** Its content
  changed with the 2026.8.2 image, and an OOBE blueprint cannot re-apply once the instance is set
  up; it is `enabled: false` and unrelated to `custom/forward-auth.yaml`. Do not chase it while
  debugging (`clear_failed_blueprints` runs hourly at `:27` and keeps retrying it upstream).

### 1d. What is deliberately *not* in the blueprint

- **Passwords** — users created without one get an unusable password, so after a fresh install they
  have to be set once (`ak changepassword <username>`, interactive, or the UI). There is no
  `ak set_password` in 2026.8. Re-applying never touches them.
- **`client_id` / `client_secret`** — generated server-side and not settable through the blueprint
  serializer; they stay stable across applies.
- **`property_mappings`** — `ProxyProviderSerializer.create()`/`.update()` both call
  `set_oauth_defaults()`, which (re-)adds the five managed proxy/oauth2 scope mappings.
- **The rest of the embedded outpost** (name, `config`, …) — only its `providers` list is managed
  (declaring `name` in that entry would trip `validate_name`'s managed-outpost side effect).
- **MFA devices** — user-side, UI only (`/if/user/#/settings`).

### 1e. Reference: `ak shell` recipes (one-off only)

Kept for experiments and for creating something outside Git during an incident. The blueprint is
authoritative for everything it declares: hand-made edits to those objects are reverted on the next
apply (list fields such as the outpost's `providers` or a user's `groups` are replaced, not merged).

#### Groups

```python
from authentik.core.models import Group
Group.objects.get_or_create(name="Platform", defaults={"is_superuser": False})
```

#### Provider + Application + binding

```python
from authentik.core.models import Application, Group
from authentik.flows.models import Flow
from authentik.outposts.models import Outpost
from authentik.policies.models import PolicyBinding
from authentik.providers.proxy.models import ProxyProvider

SLUG, NAME, HOST = "prowlarr", "Prowlarr", "https://prowlarr.480p.com"
GROUP = "Media"  # or "Platform" for the platform/observability batch

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
    target=application, group=Group.objects.get(name=GROUP),
    order=0, negate=False, enabled=True, failure_result=False,
)
print("client_id:", provider.client_id)
```

#### Users

Create accounts in the UI (`Directory → Users`). Only group membership matters for access:

```python
Group.objects.get(name="Platform").users.add(User.objects.get(username="brauni"))
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
(`kubernetes/apps/authentik/authentik/app/referencegrant.yaml`). One `from` entry **per kind and
namespace pair** — a missing `HTTPRoute` entry accepts the SecurityPolicy but leaves the outpost
route unresolved, which surfaces as an ext-auth loop rather than a clear error. Scoped today to
`flux-system`, `media`, `network`, `observability`, `volsync-system`.

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
   | echo (all 3 domains) | `/healthz` | returns 200 on any path |
   | flux-operator, konflate | `/healthz` | konflate's `/health` is 404 |
   | grafana | `/api/health` | |
   | prometheus, alertmanager | `/-/healthy` | |
   | victoria-logs | `/health` | its route has an `Exact /` rule that 302s to `/select/vmui/` |
   | kopia | `/healthz` | **no anonymous path** — skipped from ext-auth and the endpoint asserts `[STATUS] == 404` (see below) |

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

   A third option, used for **kopia**: when no path is anonymously healthy *and* the app's own
   rejection is a 404, skip that path (`^/healthz$`) and assert `[STATUS] == 404` — the 404 is
   served by the app, so a dead pod behind a live route (or a broken ext-auth chain returning 5xx)
   still goes red, while a probe on `/` would only prove that Authentik answered. Kopia's UI shell
   answers 200 on `/` and its API is what authenticates, which is why the shell is not probed.

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
Per-domain `LoadBalancer` IP: `10.10.8.15` (`envoy-480p-com-public`), `10.10.8.16`
(`envoy-brauni-dev-public`), `10.10.8.13` (`envoy-riki-boo-public`).

```bash
# 1. unauthenticated: expect 302 to sso.brauni.dev, client_id matching this app's provider
curl -sS -o /dev/null -w '%{http_code} -> %{redirect_url}\n' --resolve <app>.480p.com:443:10.10.8.15 https://<app>.480p.com/

# 2. liveness path: expect the status in the table above
curl -sS --resolve <app>.480p.com:443:10.10.8.15 https://<app>.480p.com/ping

# 3. full authenticated flow: expect 200 <title>Sonarr</title>
```

For an authenticated test, forge a session (authentik signs the session cookie, so a bare session
key is rejected — the cookie value is `SessionMiddleware.encode_session()`):

> Go through `django.contrib.auth.login()`: in 2026.8 authentication lives in an
> `AuthenticatedSession` **row** that points at the session, plus a `login_event` key in the session
> data (`SessionStore.create_model_instance()` deliberately *drops* Django's
> `_auth_user_id`/`_auth_user_backend`/`_auth_user_hash`). A hand-rolled `SessionStore()` whose row
> was inserted directly looks authenticated to nothing: the authorize view logs
> `request with no login event`, redirects to the login form, and the test then “passes” with a 200
> that is the login page — check the final hostname, not just the status code.

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
Check the `client_id` in step 1 against the provider for that hostname: it is what proves
provider matching by `Host` still works when several apps share one gateway.

Gotcha that cost an hour: **do not pass the cookie with `-H "Cookie: …"`** — curl does not carry a
hand-set `Cookie` header across redirects, so the authorize request arrives unauthenticated and the
flow silently degrades into the login form. Put it in the cookie jar instead.

Negative test: repeat with a user that is **not** in the group (`authentik_testuser1`) → the chain
stops at `sso.brauni.dev` on Authentik's "Request has been denied" page. Clean up the forged
sessions afterwards — by `sid` (`SessionStore(session_key=<sid>).delete()`) or by user agent:

```bash
kubectl -n authentik exec deploy/authentik-server -c server -- ak shell -c "
from authentik.core.models import Session
qs = Session.objects.filter(last_user_agent='curl-e2e-test')
print('MARKCLEAN', qs.count(), qs.delete())"
```

(`authentik.core.models.Session` is the model that matters — `django.contrib.sessions.models` is
unused here; the cascade also drops the `AuthenticatedSession` row. The `login_event` Events left
in the audit log are harmless.)

## Rollback

One squash commit per app ⇒ `git revert <merge-commit>`. TinyAuth stays deployed and its
ReferenceGrant already covers `media`, so a revert restores the previous behaviour immediately.
The Authentik-side objects are harmless if left behind.

## Gotchas

- **`set_oauth_defaults()`**: a raw ORM `create()`/`save()` does *not* populate `grant_types`,
  callback `redirect_uris` and the "Proxy outpost" scope mapping — the API/UI serializer does.
  Without it the provider is incomplete and login fails. Same for later edits: assign the field,
  then `set_oauth_defaults()` + `save()` if you touched anything OAuth-related. Only relevant for
  hand-written Python: the blueprint goes through `ProxyProviderSerializer`, which calls it on
  create **and** update.
- **Blueprint `identifiers` are merged into `attrs`** and matched with **all** of them ANDed, so the
  `name`/`slug` does not need repeating in `attrs`; where several objects share a target (the policy
  bindings) `order` is what disambiguates them.
- **List fields are replaced, not merged**: the outpost's `providers` and each user's `groups` are
  set to exactly what the file declares, so anything added by hand in the UI is dropped on the next
  apply (at most an hour later, usually seconds after the file changes).
- **Keep `kustomize.toolkit.fluxcd.io/substitute: disabled` on the generated ConfigMap**: the
  `skip_path_regex` values end in `$`, which Flux's `postBuild.substitute` would otherwise treat as
  a variable reference (the app Kustomization does substitute).
- **One file, not several**: blueprint files are applied per file in arbitrary order, so cross-file
  `!KeyOf`/`!Find` references can dangle — and an application with **zero** bindings is open to any
  authenticated user until the next discovery run.
- **`state: must_created` would fail here** (the objects already exist); the default `present`
  updates them in place.
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
- **`BlueprintInstance` is a DB model, not a CRD**: check/force applies through `ak shell` (see
  1c). An apply can report `successful` with the correct hash and still miss a change; re-applying
  converges. Forging a session for end-to-end tests must go through `login()` (step 5), otherwise
  the “authenticated” request is really the login form.
- **`skip_path_regex` is app-wide**: `^/ping$` exposes the liveness endpoint unauthenticated.
  That is intended for Gatus; do not widen it to paths that leak data.
- **One provider per hostname, even for one app**: `echo` served on `.480p.com`, `.brauni.dev`
  and `.riki.boo` needs three providers/applications because matching is by full `Host`; the
  Gatus swap is then three annotations on three routes.
- Authentik reference: `authorization_flow` / `invalidation_flow` slugs, provider `client_id`
  (`YF4X9tBQ…` for Sonarr) are stable; new providers get fresh client IDs, which is fine because
  the outpost is configured through the provider itself.

## Authentik-side state (Git: the forward-auth blueprint)

All of it is declared in
`kubernetes/apps/authentik/authentik/app/blueprints/forward-auth.yaml`, converted from the hand-made
API/UI objects on 2026-09-11; that file is the source of truth, and re-applying it is a no-op against
the live state below. The only real change the first apply made was normalising `Sonarr`/`Radarr` to
`invalidation_flow: default-provider-invalidation-flow` (the other 16 providers already had it,
because the API serializer sets it) — and it only landed on the **second** apply: the first reported
`successful` while both fields stayed `null` (see
[1c](#1c-applying-verifying-and-re-applying)). Confirmed afterwards through the real gateway with a
forged `brauni` session on all 18 hostnames (`200` from the app itself) and `authentik_testuser1`
ending on “Request has been denied” (see [step 5](#step-5--verification)):

- Groups `Media` and `Platform` (no roles, `is_superuser: false`), member `brauni`.
- ProxyProvider `Sonarr` (`forward_single`, `https://sonarr.480p.com`, `skip_path_regex: ^/ping$`)
  and `Radarr`; both assigned to `authentik Embedded Outpost`.
- Applications `Sonarr` (slug `sonarr`) and `Radarr` (slug `radarr`), one `PolicyBinding` each
  → Group `Media`, allow, order 0.
- Same again for `Sonarr 4K` (`sonarr4k`) and `Radarr 4K` (`radarr4k`).
- `AltMount` (`altmount`, `skip_path_regex: ^/health$`), `Clonarr` (`clonarr`, `^/api/health$`),
  `Prowlarr` (`prowlarr`, `^/ping$`) and `UmlautAdaptarrEX` (`umlautadaptarrex`, `^/api/health$`):
  `forward_single`, one application each, one `PolicyBinding` → Group `Media`, embedded outpost.
- Platform/observability batch (all `forward_single`, embedded outpost, one `PolicyBinding`
  → Group `Platform`): `Echo 480p`/`echo-480p-com` (`^/healthz$`), `Echo Brauni`/`echo-brauni-dev`
  (`^/healthz$`), `Echo Riki`/`echo-riki-boo` (`^/healthz$`), `Flux Operator`/`flux-operator`
  (`^/healthz$`), `Konflate`/`konflate` (`^/healthz$`), `Grafana`/`grafana` (`^/api/health$`),
  `Prometheus`/`prometheus` (`^/-/healthy$`), `Alertmanager`/`alertmanager` (`^/-/healthy$`),
  `VictoriaLogs`/`victoria-logs` (`^/health$`), `Kopia`/`kopia` (`^/healthz$`).
- Users `brauni` (in `Media` + `Platform`) and `authentik_testuser1` (in no group — the
  negative-test account).

Not managed, on purpose:

- **Passwords** — users created without one get an unusable password, so after a fresh install they
  must be set once (`ak changepassword <username>` or the UI). Re-applying never touches them.
- **`client_id` / `client_secret`** — generated server-side; not settable through the blueprint.
- **`property_mappings`** — re-added by `set_oauth_defaults()` on every create/update.
- **The rest of the embedded outpost** (name, `config`, …) — only its `providers` list is managed.
- **MFA devices** — user-side, UI only.

Because all of the above is (re)created from this file, it doubles as the Authentik half of a
disaster recovery: restore the database (or start clean), let the worker apply the blueprint, set the
two passwords, enroll MFA.
