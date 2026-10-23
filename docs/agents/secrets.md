# Secrets (Infisical / ExternalSecrets) — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when creating or debugging secrets
programmatically, or when an ExternalSecret misbehaves. The basic ExternalSecret template is
in the main `AGENTS.md`.

## ExternalSecret failure modes

- A missing `remoteRef` fails the **entire** ExternalSecret rather than one key, and workloads using the `Recreate` strategy get taken **down** instead of stalling the rollout — referencing an Infisical key before it exists is an outage, not a wait. Confirm the key exists first; a throwaway ExternalSecret templating `{{ .KEY | len }}` proves it without revealing the value.
- After updating a value in Infisical, force a re-read: `kubectl annotate externalsecret -n <ns> <name> force-sync=$(date +%s) --overwrite`.
- Legacy `AUTHENTIK_SECRET_KEY` contains base64 line wrapping — keep stripping newlines in the Authentik ExternalSecret template (the RC6 Rust embedded outpost uses that key as an HTTP bearer value and rejects control characters).

## Credential-splitting pattern

- `selfhosted/idlers` splits its credentials into `idlers-app-secret` (`APP_KEY` + `DB_*`) and `idlers-db-secret` (`MYSQL_*`) so the internet-facing container never receives the database root password it has no use for. Prefer this split for any app-plus-database-sidecar pod.

## Infisical EU API (differs from the public docs)

Host `https://eu.infisical.com`, project slug `ovh-ops-u1ua` (project ID via `GET /api/v1/projects`), environment `prod`:

- Universal Auth login: `POST /api/v1/auth/universal-auth/login` (body `clientId`/`clientSecret`).
- Reads: `GET /api/v3/secrets/raw?workspaceId=<project-id>&environment=prod&secretPath=...`.
- Plaintext **creates**: `POST /api/v4/secrets/<key>` (body `projectId`/`environment`/`secretPath`/`secretValue`). Plaintext **updates of existing keys**: `PATCH /api/v4/secrets/<key>` (the v4 `POST` is create-only and 400s with "already exists"; v3 write endpoints are gone/deprecated and demand KMS ciphertext).
- A folder must exist before secrets can be created inside it (`POST /api/v1/folders`).
- Plain python urllib requests get Cloudflare 1010-blocked — send a browser-like `User-Agent`.
