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
  (SSE), `/api/info`, `/api/model`, `/healthz`. The tailscale Ingress is for
  `curl`/`holmes` CLI callers, not browsing.
- Operator mode is enabled but no `ScheduledHealthCheck` exists: every check is at
  least one LLM call, so add them sparingly.
