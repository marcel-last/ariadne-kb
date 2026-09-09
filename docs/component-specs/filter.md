# Component: Open WebUI filter

**Path:** `integrations/openwebui/filter/ariadne_filter.py` · **Kind:** Open WebUI Filter function
· **Platform ref:** `docs/open-webui-integration.md`

## Responsibility
The required touchpoint. `inlet` fetches the context pack and injects it; `outlet` ships the
completed turn. Runs **inside Open WebUI's process**, so it is a single self-contained file that
imports **nothing** from this repo and talks to Ariadne only over HTTP.

## Interfaces
- `inlet(body, __metadata__, __user__, __model__)` — resolve chat→pack via
  `POST /v1/context-pack`; inject per `inject_mode` (system-merge default), stripping any prior
  `ariadne:begin…end` block first; stash `{pack_id, project_id, state_version, t0}` in
  `__metadata__["ariadne"]`.
- `outlet(body, __metadata__, __user__)` — read the correlation back; `POST /v1/turns`
  fire-and-forget with the last user+assistant messages.
- `UserValves` — `default_project`, `auto_bind_folders`, `inject_mode`.
- Defines only `inlet` + `outlet` (not `request`/`stream`) — see `docs/open-webui-integration.md` §1.4.

## Key rules
- **Fail open (INV-1):** every Ariadne call has a ≤400 ms timeout and a try/except; on any error
  return `body` unchanged. Injection never raises.
- Folder binding uses `folder_id`, which exists **only at `inlet`** (popped afterward) —
  `docs/open-webui-integration.md` §1.2.
- Exactly one system message (system-merge prepends into the existing one) — §1.6.
- Skip injection when there's no chat context (empty `chat_id`/null `session_id`) — §1.8.
- Cannot set outbound provider headers; only touches `body` — §1.7.

## Failure behaviour
The whole point: Ariadne down/slow/wrong ⇒ the chat proceeds unaugmented. `outlet` shipping is
fire-and-forget; a failed ship is picked up later by the reconciler (ADR-0008).

## Definition of done
- INV-1 fault injection: Ariadne stopped / sleeping past timeout / 500 / bad JSON → chat still
  completes; no exception escapes the filter.
- Re-injection idempotent: two turns never stack two pack blocks.
- Correlation round-trips inlet→outlet via the same `__metadata__` dict (matches
  `fixtures/openwebui/inlet-metadata.json`).
- Ships turns whose bytes match the `/v1/turns` contract; verified against
  `fixtures/openwebui/outlet-body.json`.
