# Open WebUI integration reference

**Status:** platform reference · **Verified against:** the official Open WebUI docs on
**2026-09-09** · **Applies to:** Open WebUI **0.11.x** (feature version-gates called out inline).

This file exists because Open WebUI's extension surfaces change between releases and a coding
agent's training data will be stale on them. Everything here is a *platform fact* — how Open
WebUI actually behaves — with a source link. When something here disagrees with an agent's
prior assumption, this file wins; when it disagrees with a **live instance**, the instance
wins and this file should be corrected (see `../fixtures/openwebui/` for how to capture ground
truth).

> **Pin the version.** Before building, record the exact Open WebUI image tag you target in
> `docs/config-reference.md` and re-verify the version-gated items below against that tag's
> docs/changelog. The behaviours most likely to drift are the `request` step, the
> native-vs-legacy default, and the forwarded-header names.

## Sources

All of the following were read on 2026-09-09:

- Filter Function — `https://docs.openwebui.com/features/extensibility/plugin/functions/filter`
- Functions overview — `https://docs.openwebui.com/features/extensibility/plugin/functions/`
- Tools (calling modes) — `https://docs.openwebui.com/features/extensibility/plugin/tools/`
- Tool development (native/legacy events) — `https://docs.openwebui.com/features/extensibility/plugin/tools/development/`
- OpenAPI Tool Servers — `https://docs.openwebui.com/features/extensibility/plugin/tools/openapi-servers/`
- External Tool Events — `https://docs.openwebui.com/features/extensibility/plugin/development/events/`
- Essentials (function-calling switch) — `https://docs.openwebui.com/getting-started/essentials/`
- Header helper (source) — `open_webui/utils/headers.py` (`FORWARD_USER_INFO_HEADER_*`)

---

## 1. The filter pipeline (Ariadne's required touchpoint)

A **Filter** is a Python class Open WebUI runs inside its own process, in scope either globally
or per-model. As of the current docs it has **four** hooks, not two:

| Hook | Runs | Signature (all `async`) | Ariadne uses it for |
|---|---|---|---|
| `inlet(body, ...)` | **once per user turn**, before the model call | `inlet(self, body: dict, ...) -> dict` | fetch + inject the context pack |
| `request(body, ...)` | **once per provider call** — every hop of a tool loop | `request(self, body: dict, ...) -> dict` | *(not used in v1; see §1.4)* |
| `stream(event, ...)` | per streamed chunk | `stream(self, event: dict) -> dict` | *(not used)* |
| `outlet(body, ...)` | **once per turn**, after the final response | `outlet(self, body: dict, ...) -> dict` | ship the completed turn to `/v1/turns` |

`request` was **added in v0.11.2**; `stream` in **0.5.17**. A filter that doesn't define a hook
is simply skipped for that stage, so Ariadne's filter defines only `inlet` and `outlet`.

### 1.1 Dunder parameters (inject by declaring them)

Open WebUI inspects the method signature and passes only the parameters you name. Available:

| Parameter | Contents |
|---|---|
| `__user__` | `{ id, email, name, role }` |
| `__metadata__` | `{ chat_id, session_id, user_id, files, features, params, ... }` — a **live dict** for the request (see §1.3) |
| `__model__` | full model dict; `info.base_model_id` present for workspace/custom models |
| `__event_emitter__` | `async` callable to push status/notification events to the UI |
| `__chat_id__` | the chat id (also in `__metadata__["chat_id"]`) |
| `__request__` | the raw FastAPI `Request` |

`request()` receives the **same set** as `inlet()`, plus `__features__` (the `features` dict
after the pipeline pops it off the body).

### 1.2 What's in `body`, and what disappears after `inlet`

At `inlet` the `body` is a chat-completion request: `model`, `messages`, plus Open WebUI extras.
**After `inlet` returns, the pipeline pops these keys out of the body**:
`features`, `variables`, `tool_ids`, `terminal_id`, `files`, `folder_id`, `skill_ids`,
`regeneration_prompt`.

**Consequence for Ariadne (important):** folder→project auto-binding depends on `folder_id`,
which is **only available in `inlet`**. This is why scope resolution runs in `inlet` and the
`outlet`/reconciler paths rely on the binding already established there, never on `folder_id`.
The architecture assumed exactly this; the docs confirm it.

> Verify on a live instance whether `folder_id` sits at `body["folder_id"]` or inside
> `body["metadata"]`. The docs list it among body keys; the fixture capture (`../fixtures/openwebui/`)
> is how you nail down the exact path before writing the resolver.

### 1.3 inlet ↔ outlet correlation via `__metadata__` — Ariadne's mechanism

`__metadata__` is **the same dict object** across the request lifecycle, so whatever the filter
stashes in `inlet` is readable in `outlet` on that same request. This is precisely the
`Correlation` object in `openapi/ariadne-api.yaml` (`pack_id`, `project_id`, `state_version`,
`t0`): the filter writes it into `__metadata__["ariadne"]` during `inlet` and reads it back in
`outlet` to attach to the `/v1/turns` payload. Confirmed behaviour, not a workaround.

```python
async def inlet(self, body, __metadata__=None, __user__=None):
    pack = ariadne.context_pack(chat_id=__metadata__["chat_id"], ...)   # HTTP call to Ariadne
    __metadata__["ariadne"] = {"pack_id": pack["pack_id"],
                               "project_id": pack["project_id"],
                               "state_version": pack["state_version"]}
    # inject pack into body["messages"] (see §1.6)
    return body

async def outlet(self, body, __metadata__=None, __user__=None):
    corr = (__metadata__ or {}).get("ariadne")
    ariadne.ship_turn(chat_id=__metadata__["chat_id"], messages=body["messages"][-2:], correlation=corr)
    return body
```

### 1.4 Why Ariadne uses `inlet`, not `request`, for injection

`inlet` runs **once per turn**; `request` runs **once per provider call**, and a tool-using turn
makes several calls. The pack must be injected once, so `inlet` is correct. The docs also warn
that something added in `inlet` "can be dropped from later [calls] as the message list is rebuilt
for each follow-up" — so within a long tool loop the injected pack may not persist to every hop.
For v1 that's acceptable (the pack anchors the turn's first call, which is where continuity
matters). If a future need requires the pack on *every* hop, that's what `request` is for — but
it must then be written **idempotently** (guard on a sentinel already present in `messages`),
because `request` re-runs on the whole conversation each hop.

### 1.5 Failure behaviour — and why Ariadne still guards itself

Per the docs, **`inlet` failures are logged at debug and otherwise treated gently**, while
`request`, `stream` and `outlet` **re-raise** and the call site turns the exception into a failed
turn. That's favourable for Ariadne (injection is in `inlet`), but the "never break a chat"
invariant does **not** lean on it: the filter wraps every Ariadne HTTP call in its own timeout
(≤ 400 ms) and try/except and always returns `body` unchanged on any error. Two reasons: `outlet`
is the un-gentle one and that's where we ship turns, and relying on undocumented-in-detail
"gentleness" is fragile across versions.

### 1.6 Injecting the pack

Open WebUI expects **exactly one system message**. The two supported injection modes map to:

- **system merge (default):** prepend the pack (inside its sentinels) to the existing system
  message content, or insert one system message at index 0 if none exists —
  `body.setdefault("messages", []).insert(0, {"role": "system", "content": pack_text})`.
- **user_prefix:** prepend the pack to the latest user message's content.

Both are documented filter patterns. The filter strips any prior `ariadne:begin…end` block
before injecting, so re-injection never stacks (see `specs/context-pack.md` §7).

### 1.7 A filter cannot set outbound HTTP headers

Filters modify the request **body** only; the outbound headers to the model provider are built
separately and can't be influenced from a filter. This doesn't affect Ariadne: the filter talks
to the **Ariadne service** directly over its own HTTP client (adding `X-Ariadne-Key` /
`X-Ariadne-Identity` itself), and does not try to route anything through the model call.

### 1.8 Detecting WebUI vs direct-API turns

There's no caller field. A WebUI request carries a non-empty `chat_id` **and** non-null
`session_id` in `__metadata__`; a plain API call has an empty `chat_id` and `null` `session_id`
(both keys always exist — test values, not presence). Ariadne's filter uses this to skip
injection when there's no real chat context.

---

## 2. `outlet` on direct API calls — the reconciler's reason to exist

This is the sharpest platform gotcha for Ariadne and it's version-dependent:

- **Tagged releases / `main`:** `outlet()` is **not** called by `POST /api/chat/completions`.
  It runs only if the caller makes a second call to `POST /api/chat/completed` with the full
  conversation. So a user driving Open WebUI's API directly (not the web UI) produces turns that
  **never reach Ariadne's `outlet`**.
- **`dev` / upcoming:** `outlet()` runs for direct callers by default, gated by
  `ENABLE_API_OUTLET_FILTERS` (default `True`); on streaming it runs after the stream completes.

Either way, `outlet` side-effects (like Ariadne's fire-and-forget ship) execute, but Open WebUI
does **not** fold the result back into the HTTP response. That's fine for Ariadne (we don't
rewrite responses). The real implication: **turn capture via `outlet` is best-effort and can miss
direct-API turns**, which is exactly why the architecture includes the **reconciler** — it reads
the Open WebUI chat REST API and backfills any turns `outlet` didn't deliver. Idempotency on
`(project_id, content_hash)` (see `specs/queue-messages.md`) makes the overlap safe.

---

## 3. Tool servers (Ariadne's recommended touchpoint)

Ariadne's `ariadne-tools` (see `openapi/ariadne-tools.yaml`) is registered as an **OpenAPI tool
server** under *Settings → Integrations* (Open WebUI **v0.6+**). The model calls the tools; Open
WebUI forwards the tool arguments to the server as an HTTP request.

### 3.1 The forwarded headers — Ariadne's binding source

When **`ENABLE_FORWARD_USER_INFO_HEADERS=True`** (⚠️ **off by default**), Open WebUI adds these
headers to **every external tool request**:

| Header | Value | Ariadne use |
|---|---|---|
| `X-OpenWebUI-Chat-Id` | current chat id | **resolve the project** (chat→project binding) |
| `X-OpenWebUI-Message-Id` | current message id | correlation / event callbacks |
| `X-OpenWebUI-User-Id` | user id | mint the `X-Ariadne-Identity` claim (`sub`) |
| `X-OpenWebUI-User-Email` | user email | identity claim `email` |
| `X-OpenWebUI-User-Name` | user name | identity claim (display) |
| `X-OpenWebUI-User-Role` | `admin` / `user` | identity claim `role` |

The exact header strings come from `FORWARD_USER_INFO_HEADER_USER_{ID,EMAIL,NAME,ROLE}` in
`open_webui/utils/headers.py`; the values above are the defaults. **This is the entire basis of
the tool-server binding invariant**: the tool never takes a `project_id`, it reads
`X-OpenWebUI-Chat-Id` and resolves server-side (architecture §5.2). If the header is absent, the
tool call fails **closed** with 428 — the model must never be able to pick a project.

### 3.2 If the admin won't flip the global flag

`ENABLE_FORWARD_USER_INFO_HEADERS` is instance-wide and off by default; some operators won't
enable it. Fallback, documented for the events endpoint and usable here: on the Ariadne tool-server
**connection**, configure a **per-connection custom header** using the `{{CHAT_ID}}` (and
`{{MESSAGE_ID}}`) placeholder, which Open WebUI interpolates **regardless of the global flag**.
So the deployment guide should say: *either* set `ENABLE_FORWARD_USER_INFO_HEADERS=True`, *or*
add a per-connection header like `X-OpenWebUI-Chat-Id: {{CHAT_ID}}` on the Ariadne connection.
Note the placeholder path only reliably delivers chat/message id, not the user identity headers —
so with the per-connection fallback, Ariadne derives the user from the service key's tenant + a
looser identity, and must not depend on `X-OpenWebUI-User-*` being present. Verify both paths on
the target instance.

### 3.3 Constraints on external tools (vs native Python tools)

- **One-way events only.** The server can emit status/notification events by POSTing to
  `/api/v1/chats/{chat_id}/messages/{message_id}/event`, but **interactive** events (prompt the
  user, confirmations) need a native Python tool — not available to OpenAPI servers.
- **No streaming.** Tool responses return as complete results.
- **No `__user__` object.** External servers get the *headers* above (when enabled), not Open
  WebUI's Python `__user__`. Ariadne relies only on the headers.
- **Descriptions are the tool prompt.** Open WebUI uses the OpenAPI operation descriptions when
  building the tool spec for the model, so `openapi/ariadne-tools.yaml` descriptions are written as model
  instructions.

### 3.4 Event callback (optional, for progress)

To show "Recalling memory…" style progress, the tool server can POST an event to
`/api/v1/chats/{chat_id}/messages/{message_id}/event` using an **admin/service-account API key**
stored on the server (Open WebUI does not push a key to you). One admin key serves all users; the
forwarded chat/message ids say which message to attach to. This is optional polish for v1.

---

## 4. Function-calling mode: Native is the default now (and the detection trap)

**As of v0.10.0, Native (Agentic) function calling is the default.** The old prompt-injection
mode was renamed **Legacy** (formerly "Default") and is **unsupported** — no built-in tools, and
incompatible with modern features. Ariadne needs Native for multi-round tool use
(recall → remember → answer), so this default is favourable.

**The trap (from the tool-development docs):** before v0.10.0 an unset model carried the string
`"default"` and code detected native via `function_calling == "native"`. That is now **wrong** —
an unset model runs Native but does **not** carry `"native"`. Any Ariadne code that inspects the
mode (e.g. the reconciler or a diagnostics probe) must **test for `== "legacy"` and treat
everything else as Native.** A stale `== "native"` check misclassifies the now-default case.

Deployment guidance for Ariadne: require Native, and if a model was forced to Legacy, document
that Ariadne's tool surface won't work there and the filter-only (pack injection) path is the
fallback.

---

## 5. What this pins down for Ariadne — decision ledger

| Ariadne design point | Platform fact confirming / constraining it | Source |
|---|---|---|
| Pack injection in `inlet`, once per turn | `inlet` runs once per turn; `request` runs per call | Filter docs §request |
| Correlation via `__metadata__["ariadne"]` | `__metadata__` is one live dict across inlet→outlet | Filter docs §correlation |
| Folder binding only in `inlet` | `folder_id` popped from body after `inlet` | Filter docs §request pipeline |
| Reconciler is mandatory, not optional | `outlet` skipped for direct `/api/chat/completions` on tagged releases | Filter docs §API behaviour |
| Idempotent ingest on content_hash | outlet + reconciler can both deliver the same turn | derived |
| Tool server binds via `X-OpenWebUI-Chat-Id` | that header is forwarded to external tools (flag on) | OpenAPI/Events docs |
| Tools fail closed (428) without chat id | header off by default; absence must not fall through | derived + Events docs |
| Per-connection `{{CHAT_ID}}` fallback | interpolated regardless of the global flag | Events docs |
| Require Native function calling | Native default since 0.10.0; Legacy unsupported | Tools docs |
| Detect mode by `== "legacy"` | unset model no longer carries `"native"` | Tool dev docs |
| Filter talks to Ariadne over its own HTTP | filters cannot set outbound provider headers | Filter docs |

---

## 6. Still to verify against a live instance

The docs are authoritative for behaviour but not for exact serialized shapes. Capture these from
a running instance (recipe in `../fixtures/openwebui/README.md`) before finalising the resolver
and the turn normaliser:

1. Exact location of `folder_id` at `inlet` (`body["folder_id"]` vs `body["metadata"]`).
2. Exact shape of `body["messages"]` items (content as string vs content-part array; where file
   references live).
3. The precise `__metadata__` keys present on a real WebUI turn (esp. `chat_id`, `session_id`,
   `message_id`, `params`, `variables`).
4. Whether the target release forwards **user** headers to tool servers or only chat/message id.
5. `outlet` body shape (does it carry the full `messages` array incl. the new assistant turn?).
