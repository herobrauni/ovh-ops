# Stalwart + Bulwark SSO through authentik — built, then rolled back

**Status: disabled (2026-11-25).** Stalwart and Bulwark run on Stalwart's internal directory with plain
credentials. This document is the complete recipe for re-enabling SSO, the traps that cost hours, and the
rollback that was applied. Repo state for "off" lives in
`kubernetes/apps/authentik/authentik/app/blueprints/mail-sso-retired.yaml` (an explicit `state: absent`
retirement) and in `kubernetes/apps/stalwart/bulwark/app/helmrelease.yaml` (no `OAUTH_*` env).

## Why it was rolled back

It worked end to end, but the architecture is lopsided for two mail users:

- **One directory, one issuer.** Stalwart (Community) has a single default directory, so it validates the
  token's `iss` against a single `issuerUrl`, while authentik derives the issuer from the **application
  slug**. The webmail and the Stalwart WebUI therefore cannot have separate clients.
- **That forces a public client.** The WebUI can only do `token_endpoint_auth_method: none`, so the shared
  client must be public/PKCE — which also means the webmail stops having a secret.
- **Everything is DB-resident on the Stalwart side.** Directory, `Authentication.directoryId` and
  `x:Application` are registry objects set through the WebUI/JMAP API, not manifests, so this half of the
  configuration cannot be reviewed or restored through Git.
- **It takes the whole domain with it.** With `directoryId` set, password authentication for the internal
  accounts stops (no fallback, per-domain directories are Enterprise-only), so every IMAP/SMTP client has to
  migrate to app passwords or OAuth.

## Topology when it was enabled

```
browser ──▶ webmail.480p.com (Bulwark) ──bearer──▶ stalwart.480p.com (JMAP, resource server)
   │                    │                                   ▲
   └──▶ sso.brauni.dev (authentik, one public client: `bulwark`)
                        └── issuer https://sso.brauni.dev/application/o/bulwark/
stalwart.480p.com/admin (WebUI) ── same client, its own redirect URIs
```

Both clients used the **same** `client_id=bulwark`, which is the whole trick: the directory's `issuerUrl`,
the webmail's `OAUTH_ISSUER_URL` and the WebUI's `oauthClientId` all have to agree on one application.

## Re-enabling, in order

1. **authentik**: restore the provider/application (revert the rollback commit, or rebuild from the retired
   file's history). It is a public client with `openid`, `email` (custom mapping
   `f"{request.user.username}@480p.com"`), `profile`, **`offline_access`** scope mappings, and redirect URIs:
    - `https://webmail\.480p\.com/([a-z]{2}/)?auth/callback` (regex — Next.js localizes the path)
    - `https://stalwart.480p.com/{admin,account}/oauth/callback` and the `mail.480p.com` twins (strict)
      Validate with `Importer.from_string(...).validate()` in the worker, then apply — `ak shell` on
      `authentik-server` OOMs, use the worker.
2. **Stalwart**: create the OIDC directory (WebUI › Settings › Authentication › Directories) or via JMAP
   `x:Directory/set`:
   `@type: Oidc`, `issuerUrl: https://sso.brauni.dev/application/o/bulwark/` (exact, trailing slash),
   `claimUsername: preferred_username` + `usernameDomain: 480p.com` (or `claimUsername: email`),
   `claimName: name`, `claimGroups: groups`, `acceptedAudiences: {bulwark: true}`,
   `unscopedTokens: full`, `trustedProvider: true`.
3. **Stalwart**: `x:Authentication/set` → `{"singleton":{"directoryId":"<directory id>"}}` and
   `x:Application/set` → `{"<webui app id>":{"oauthClientId":"bulwark","oauthScopes":{"offline_access":true}}}`.
4. **Reload every pod** — `x:Action/set` with `{"create":{"a1":{"@type":"ReloadSettings"}}}` **only reloads
   the pod that handled the call**; hit each replica through `kubectl port-forward pod/stalwart-<n> 8080`.
5. **Restart the pods** — the WebUI's `<meta name="oauth-client-id">` and `<meta name="oauth-scopes">` are
   rewritten when the app bundle is unpacked at boot, so a reload leaves them empty and the WebUI reports
   _"Sign-in is not configured…"_.
6. **Bulwark**: `OAUTH_ENABLED`, `OAUTH_CLIENT_ID=bulwark`, `OAUTH_ISSUER_URL` (trailing slash is required by
   Stalwart's discovery but has **not** to be doubled for Bulwark's own discovery — copy the value that was
   verified working), `OAUTH_SCOPES: openid email profile offline_access`, and for the authentik app tile
   `OAUTH_ONLY=true` + `AUTO_SSO_ENABLED=true`. No client secret: the client is public.

## Verification (no browser needed)

```sh
# 1. Stalwart accepts an IdP token and maps it to a local account
TOK=$(kubectl -n dbms exec postgres18-1 -c postgres -- bash -c "PGPASSWORD=... psql -h 127.0.0.1 \
  -U authentik -d authentik -A -t -c \"select token from authentik_providers_oauth2_accesstoken \
  where token like 'ey%' and expires > now() order by id desc limit 1;\"")
curl -sS -H "Authorization: Bearer $TOK" https://stalwart.480p.com/jmap/session   # -> username: <user>@480p.com

# 2. The issuer the WebUI/S PA will use matches the directory
curl -sS 'https://stalwart.480p.com/api/discover/brauni%40480p.com' | python3 -m json.tool

# 3. The static client id and extra scopes actually reached the SPA
curl -sS https://stalwart.480p.com/admin/ | grep -o '<meta name="oauth-[^>]*>'
curl -sS https://webmail.480p.com/api/config | python3 -m json.tool
```

`GET /api/schema/<Object>` (follow the 302) returns Stalwart's whole field/form/enum catalogue — that is how
to look up a field or action name instead of guessing. `/api/discover/<user>` is the fastest way to see which
issuer an account resolves to.

## Traps (in the order they bit)

1. **`offline_access` needs its own scope mapping.** A provider's property mappings _are_ its declared
   scopes; an unrequested mapping is silently dropped, and `providers/oauth2/views/token.py` only mints a
   `RefreshToken` when the granted scopes contain `offline_access`. Symptom: the OAuth round trip completes,
   the app force-refreshes, gets `401` and wipes its session — "logged out instantly". Check with
   `select count(*) from authentik_providers_oauth2_refreshtoken where provider_id=<pk>` (0 = never issued).
2. **Single issuer (see above).** With a second client, authentik mints tokens with `iss …/o/stalwart/` while
   the directory trusts `…/o/bulwark/`; Stalwart answers **401 with no log line at all** (no
   `auth.failed`, no error) — only a token `iss` comparison reveals it.
3. **`ReloadSettings` is per instance**, and it is not a `x:…/create`: it is `x:Action/set` with
   `{"create":{"a1":{"@type":"ReloadSettings"}}}`. After enabling a directory the Service answers `401`
   roughly two times out of three until every replica is reloaded.
4. **The WebUI's client id/scopes are baked in at boot.** `UpdateApps` does not help; deleting the pods does.
5. **The WebUI needs `offline_access` in `x:Application.oauthScopes`.** Its SPA requests exactly
   `stalwart_required_scopes` from `/api/discover` (`openid profile`) plus whatever the meta tag adds, and
   Stalwart strips `offline_access` from the proxied `scopes_supported`. Without the meta entry the SPA's
   refresh path throws `expireSession()` immediately — _"Your session has expired. Please sign in again."_
6. **The authentik app tile only opens a URL.** It never starts a flow; without `AUTO_SSO_ENABLED` the user
   lands on a login form and looks signed out.
7. **`claimGroups: groups` provisions local groups** (`Media`, `Platform`, `Silo`, `Mail`) on the first
   successful token. Roles stay per-Account / per-group in Stalwart; authentik does not grant them.
8. **First login before mail delivery.** With an OIDC directory, accounts are created locally on first use,
   so an address that never signed in is not a mailbox. The domain's `catchAllAddress` (`brauni@480p.com`)
   swallows such mail instead of bouncing it — easy to misread as "it already works".

## Rolling back again (what was done on 2026-11-25)

1. Stalwart: `x:Authentication/set` → `directoryId: null`; `x:Application/set` →
   `oauthClientId: null, oauthScopes: {}`; reload each pod, then restart them so the meta tags are rewritten.
   The internal passwords were never removed, so password auth comes straight back.
2. Bulwark: drop every `OAUTH_*` env var (defaults disable OAuth and show the password form again).
3. authentik: `mail-sso-retired.yaml` (`state: absent` for application `bulwark`, its policy binding, provider
   `Bulwark OIDC`, scope mapping `Bulwark Email Mapping`, plus the long-gone `stalwart` app/provider).
   Blueprints never delete objects they stop managing, so an explicit absent entry is required.
4. Verify: `/admin` meta tags empty, `/api/config` shows `oauthEnabled: false`, and `authentik_core_application`
   has no `bulwark`/`stalwart` rows.
