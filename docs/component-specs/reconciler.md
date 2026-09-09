# Component: ariadne_reconciler

**Path:** `packages/ariadne_reconciler/` · **Kind:** periodic service · **Decision:** ADR-0008

## Responsibility
Guarantee "nothing is lost" (goal G3) by backfilling turns the `outlet` path didn't deliver —
notably direct `/api/chat/completions` API turns, for which Open WebUI does not fire `outlet` on
tagged releases (`docs/open-webui-integration.md` §2). This is why the reconciler is mandatory,
not optional.

## Consumes
The Open WebUI chat REST API (read), using a service-account/admin key; a per-chat high-water mark
(persisted) of the last reconciled message.

## Produces
`POST /v1/turns` calls (`source: reconciler`) for any messages past the high-water mark.

## Key rules
- Idempotent by construction: ingestion dedupes on `(project_id, content_hash)`, so overlap with
  `outlet` is harmless — INV-5. The reconciler need not know what `outlet` already shipped.
- Only backfills chats already bound to a project (binding is established at `inlet`); it does not
  invent bindings.
- Rate-limited and cursored so it doesn't hammer the Open WebUI API.

## Failure behaviour
Best-effort and idempotent; a crashed run resumes from the stored high-water mark. Never blocks
anything; purely additive.

## Definition of done
- A turn produced via direct API (no `outlet`) is present in T0 within one reconcile interval.
- INV-5: a turn delivered by *both* `outlet` and the reconciler yields exactly one `event`.
- High-water mark advances monotonically per chat; a restart does not re-ingest old turns
  (they'd dedupe anyway, but the cursor avoids the work).
