# Component: ariadne_tools

**Path:** `packages/ariadne_tools/` · **Kind:** model-facing HTTP service · **Contract:** `openapi/ariadne-tools.yaml`

## Responsibility
Expose the memory operations the **model** may call, registered in Open WebUI as an OpenAPI tool
server. Translate each call into an `ariadne-api` call against `@chat:<chat_id>` with a freshly
minted identity claim. Hold **no** business logic — resolution and enforcement live in the API.

## Consumes
HTTP tool calls from Open WebUI, carrying `X-OpenWebUI-Chat-Id` (+ user headers) when
`ENABLE_FORWARD_USER_INFO_HEADERS=true` or a per-connection `{{CHAT_ID}}` header is set
(`docs/open-webui-integration.md` §3).

## Produces
`ariadne-api` calls (`recall`, `memories`, `state`, `checkpoint`, `restore`, `artifact`) and their
results, shaped for the model.

## Key rules — this is a safety boundary
- **No operation accepts a project id** — the project is derived from `X-OpenWebUI-Chat-Id`. INV-3.
- Missing chat id / unbound chat → **428, fail closed**. Never fall back to a default project.
- Mints `X-Ariadne-Identity` from the forwarded user headers (or a degraded identity under the
  per-connection fallback); never trusts a body-supplied identity.
- Descriptions in the OpenAPI are the model's tool prompts — keep them terse and imperative.

## Failure behaviour
API `4xx/5xx` are surfaced to the model as short, actionable messages (e.g. "memory unavailable,
answer from context"); the tool server adds no retries that could reorder writes.

## Definition of done
- INV-3: schema test — no operation has a `project*` property; behaviour test — no chat id ⇒ 428;
  a call for chat A never returns chat B's memory.
- Every tool round-trips through `@chat:` to the API and back with a valid minted claim (≤300 s).
- Native function-calling assumed (ADR-0007); documented as a precondition.
