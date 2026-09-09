# ADR-0005: Server-derived project binding + two-header auth

**Status:** Accepted

## Context
The model must be able to *use* project memory but must never be able to *choose* which project
it touches, or a prompt-injected model could read/rewrite another project. Callers (filter, tools,
reconciler) act on behalf of a specific tenant and user that must be proven, not asserted.

## Decision
The project is always resolved **server-side** from the chat binding (chat_id → project); no
model-facing operation accepts a `project_id`, and an unbound/absent chat id fails **closed**
(`428`). Authentication is two headers: `X-Ariadne-Key` (per-tenant service key → tenant) and
`X-Ariadne-Identity` (HS256 JWT, ≤ 300 s → user). Body-supplied ids are ignored when a header or
binding can supply them. Secrets are never stored (reference-only).

## Alternatives rejected
- **Let the model pass a project id/slug** — the exact cross-project hole we're closing.
- **Single API key only** — can't distinguish users for ACL/RLS or audit.
- **Long-lived identity tokens** — a leaked token becomes a standing impersonation.

## Consequences
- `openapi/ariadne-tools.yaml` has zero project parameters; binding lives in one place
  (`ariadne_api/scope.py`); the `@chat:<chat_id>` path param lets the tool proxy address the API.
- Requires header forwarding in Open WebUI (`ENABLE_FORWARD_USER_INFO_HEADERS` or a per-connection
  `{{CHAT_ID}}` header) — documented in `docs/open-webui-integration.md` §3.
- Enables RLS (INV-11) and short-lived identity (INV-12) and secret-exclusion (INV-10).

## Produces / relates to
INV-3, INV-10, INV-11, INV-12 · `openapi/ariadne-tools.yaml`, `openapi/ariadne-api.yaml`, `db/migrations/0006_rls.sql`
