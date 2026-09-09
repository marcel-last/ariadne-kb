# Component: ariadne_api

**Path:** `packages/ariadne_api/` · **Kind:** HTTP service · **Contract:** `openapi/ariadne-api.yaml`

## Responsibility
Serve the service API: the hot-path `POST /v1/context-pack` and `POST /v1/turns`, plus project /
state / memory / session / job management. Own **scope resolution** (chat → project binding) and
the **pack builder** (separate spec). Enforce auth, tenancy, optimistic concurrency, and RFC 9457
errors.

## Structure
- `routers/` — one per tag in the OpenAPI (pack, turns, projects, state, memory, sessions, jobs, ops).
- `scope.py` — the resolution ladder: existing binding → slash command → folder map (inlet only)
  → `default_project` UserValve → implicit `chat-<short id>`. Records `bound_by`. Accepts the
  `@chat:<chat_id>` project ref used by the tool proxy.
- `pack/` — the pack builder (see `pack-builder.md`).
- `recall.py` — hybrid vector+lexical fusion for `POST /v1/recall` and for the pack's recall slot.
- `errors.py` — maps typed errors to `Problem` with the stable `code` enum.

## Consumes
`ariadne_common` (db, auth, redis, schemas); Postgres; Redis (enqueue to `ariadne:ingest`,
`ariadne:jobs`; read pack cache).

## Produces
HTTP responses per the OpenAPI; stream entries for the worker; state versions + history rows.

## Key rules
- `POST /v1/context-pack` must be fast and **fail-open-friendly**: it never does blocking heavy
  work; on dependency trouble it may return `503` (the filter then proceeds unaugmented) — INV-1.
- `POST /v1/turns` only validates + resolves + enqueues, returns `202` (or inline-persists if
  `XADD` fails, per ADR-0009); idempotent per `content_hash` — INV-5.
- `PATCH /state` enforces `base_version` → `409 version_conflict` — INV-7; re-validates result — INV-4.
- Every request sets the tenant GUC from the verified claim before any tenant-scoped query — INV-11.
- `@chat:<id>` resolves through the binding; unknown/absent binding on a model-facing path is a
  fail-closed error, never a fallback project — INV-3.

## Failure behaviour
Dependency down → `503` on hot paths (caller fails open), `500 internal` elsewhere, always as
`problem+json`. Never leak whether a resource exists across tenants (`404` not `403` for
cross-tenant) — matches the OpenAPI `NotFound` note.

## Definition of done
- Contract tests generated from `openapi/ariadne-api.yaml` pass (request/response shapes, error
  codes).
- INV-1 fault tests: `context-pack`/`turns` degrade, never 5xx-hang the caller past the budget.
- INV-3: no code path lets a caller-supplied project id override a binding on a model-facing route.
- INV-5/INV-7/INV-11 checks (idempotent turns; version conflict; tenant isolation) pass.
