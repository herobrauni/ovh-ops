# HolmesGPT — agent topic guide

Part of the `AGENTS.md` topic guides (`docs/agents/`). Read when touching
`kubernetes/apps/observability/holmesgpt`.

- Deployed from the upstream `robusta/holmes` chart via a pinned `HelmRepository`
  (`https://robusta-charts.storage.googleapis.com`), not app-template: the chart
  ships the read-only ClusterRole, the ServiceAccount and the operator CRDs
  (`healthchecks` / `scheduledhealthchecks` / `triggeredhealthchecks.holmesgpt.dev`).
- Model access is direct against OpenCode Go, no litellm hop:
  `OPENAI_API_BASE=https://opencode.ai/inference/go/openai/v1` (pay-as-you-go is
  `.../inference`, Go is `.../inference/go`). Go **requires** an
  `x-opencode-session` header (otherwise `400 MissingSessionID`) and a real client
  User-Agent, both injected through Holmes' `EXTRA_HEADERS` env hook — see
  `holmes/core/llm.py` `completion()`. An empty pay-as-you-go balance returns
  `402 Insufficient account funds`; free models return `429 FreeUsageLimitError`
  for non-OpenCode clients.
- **Header passthrough quirk (cost us a debugging round):** Holmes propagates
  every incoming HTTP header into shell-backed toolsets and rejects values with
  shell metacharacters (`/_SHELL_METACHARACTERS` in `holmes/core/tools.py`,
  ROB-1104). `curl` sends `Accept: */*` and the tailscale ingress injects
  `Tailscale-User-*` headers carrying URLs, so **all `kubernetes/*` toolsets fail
  with "request header '…' contains disallowed shell metacharacter(s)"** while
  the Prometheus/VictoriaLogs (Python) toolsets keep working. `_build_context`
  sanitises the whole header dict even when no tool template references it, so
  any client can poison it. Fix in place: the broad
  `HOLMES_PASSTHROUGH_BLOCKED_HEADERS` list in the HelmRelease blocks the
  conventional + `tailscale-user-*` headers; if a new client sends a new
  metacharacter-laden header, add it there.
- There is **no web UI** in the OSS server — `/` 404s, the API is `/api/chat`
  (SSE), `/api/info`, `/api/model`, `/healthz`. The tailscale Ingress
  (`https://holmesgpt.<tailnet>.ts.net`) is for API callers. The only upstream
  "web UI" is the **Robusta Platform** (`docs/installation/ui-installation.md`,
  titled "3rd party"): SaaS is free to start, self-hosted is an Enterprise plan,
  and Robusta's own docs say standalone HolmesGPT is "CLI only — no web UI".
- Operator mode is enabled but no `ScheduledHealthCheck` exists: every check is at
  least one LLM call, so add them sparingly.
- **Remediation MCP** (`mcpAddons.kubernetesRemediation`) gives Holmes the write
  half: restart/scale/drain/patch, file reads inside containers, and short-lived
  netshoot/busybox diagnostic pods. Mutations always pause for human approval
  (`approval_required_tools: run_kubectl_command`); the chart adds a scoped
  ClusterRole (no `secrets`, no `cluster-admin`), an ingress-only NetworkPolicy,
  and a **pre-install/pre-upgrade hook Job** (`…-k8s-remediation-mcp-auth-bootstrap`)
  that mints the MCP bearer token — that Job is expected to exist per upgrade,
  don't "clean it up". If the approval prompt is ignored (e.g. an API caller
  that never approves), the mutating tool just returns `pending_approvals`.
- **Laptop access is MCP, not a UI.** `~/.config/holmes-mcp/server.py` (run via
  `run.sh` → `uv run --with 'mcp>=2,<3'`) is a stdio MCP shim exposing
  `ask_holmes` and `holmes_status`; registered as `holmes` in
  `~/.pi/agent/mcp.json` with `timeout: 1200` (investigations exceed the 60s
  default). It only talks to the tailnet API, so it needs no cluster credentials.
- **Grafana**: `grafana/dashboards` uses a **Viewer** service account
  (`holmes-readonly` in Grafana 12) whose token lives at
  `/holmesgpt/GRAFANA_API_KEY`. Minting it needs the admin pair **split across two
  secrets** (`grafana-admin-credentials.GF_SECURITY_ADMIN_USER` +
  `grafana-admin-password-secret.GF_SECURITY_ADMIN_PASSWORD`) — using the
  password from the first secret returns 401. No image renderer is installed, so
  the visual-rendering tools stay unregistered.
- **Postgres**: read-only via the **CNPG-managed** role `holmes_readonly`
  (`pg_read_all_data` + `pg_read_all_stats`, `login` only) declared in
  `dbms/cloudnative-pg/cluster/cluster18.yaml`, with its password from
  `/holmesgpt/POSTGRES_READONLY_PASSWORD` (same value feeds the role and the
  Holmes connection URL). Toolsets connect over the replica service
  `postgres18-ro` to `litellm`, `patchmon`, `open-webui` only.
  `pg_read_all_data` is cluster-wide, so the safety boundary is _which databases_
  we hand over — `authentik`, `vaultwarden`, `immich`, `firefly3` are excluded on
  purpose. Adding a DB = copy one block in the HelmRelease.
- Toolsets deliberately **not** connected: `helm/core` (needs `secrets` read),
  `cilium`+`hubble` (no `cilium`/`hubble` binaries in the image and Hubble is
  disabled in `kube-system/cilium`), `inspektor-gadget` (privileged
  `kubectl debug` on nodes), `github-mcp` (needs a repo/write PAT).
