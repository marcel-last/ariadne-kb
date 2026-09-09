# ADR-0008: Turn capture is best-effort `outlet` + a mandatory reconciler

**Status:** Accepted

## Context
`outlet` is the natural place to ship a completed turn, but Open WebUI does **not** invoke
`outlet` for direct `/api/chat/completions` API callers on tagged releases (only via a second
`/api/chat/completed` call). So `outlet` alone silently misses direct-API turns, violating "nothing
is lost" (goal G3).

## Decision
Ship turns opportunistically from `outlet`, and run a **mandatory reconciler** that periodically
reads the Open WebUI chat REST API and backfills any turns not already ingested. Overlap is made
safe by idempotency.

## Alternatives rejected
- **Rely on `outlet` only** — loses direct-API turns; G3 fails.
- **Poll the REST API for everything, skip `outlet`** — adds latency to continuity and hammers the
  API; `outlet` is cheaper when it fires.
- **Require every API caller to also call `/api/chat/completed`** — not enforceable for third-party
  callers.

## Consequences
- Ingestion must be idempotent on `(project_id, content_hash)` (INV-5); `TurnAccepted.deduplicated`
  reports absorbed duplicates.
- The reconciler needs read credentials to the Open WebUI API and a per-chat high-water mark.
- Capture latency varies (instant via `outlet`, up to the reconciler interval via backfill); the
  brief's `stale_turns` communicates lag.

## Produces / relates to
INV-5 · `docs/open-webui-integration.md` §2, `specs/queue-messages.md`, `openapi/ariadne-api.yaml` (`/v1/turns`)
