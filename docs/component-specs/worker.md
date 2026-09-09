# Component: ariadne_worker

**Path:** `packages/ariadne_worker/` · **Kind:** Redis Streams consumer · **Spec:** `specs/queue-messages.md`

## Responsibility
Consume `ariadne:ingest` and run the pipeline **persist → embed → extract → summarize**, and
consume `ariadne:jobs` for `merge`/`rebuild`/`purge`/`export`. This is where all the heavy,
asynchronous work lives (ADR-0004 keeps it off the hot path).

## Structure
- `stages/persist.py` — assign per-project `seq` (`ariadne_next_seq`, Redis lock + PG advisory
  fallback), insert `event` with `ON CONFLICT (project_id, content_hash) DO NOTHING`.
- `stages/embed.py` — batch-embed new memories/chunks, fill `memory.embedding`.
- `stages/extract.py` — run `prompts/extractor.md`, validate against
  `schemas/extractor-output.schema.json`, apply patch with `base_version` concurrency, index memories.
- `stages/summarize.py` — segment/session/project roll-ups.
- `jobs/` — the long-running operations; update the `job` row's `status`/`progress`.

## Consumes
`ariadne:ingest`, `ariadne:jobs`; the extractor + embedding model endpoints; Postgres; Redis.

## Produces
`event`, `memory`, `summary`, `state_doc(+history)` rows; `stage_cursor` advances; DLQ entries.

## Key rules
- Per-project ordering; `seq` gap-free and monotonic — INV-6.
- Idempotent on `(project_id, content_hash)`; at-least-once + `XACK`/`XAUTOCLAIM` (min-idle 60 s);
  `INGEST_MAX_ATTEMPTS` → `ariadne:dlq` — INV-5.
- Stages independent and idempotent; extraction failure keeps T0/T3, retries once, then defers
  T1 — INV-13. Never block ingest on the extractor.
- `purge` removes every tier + object-store prefix + cache, then the project row — INV-14.

## Failure behaviour
A stage error re-queues (up to max attempts) then DLQs; it never corrupts T0. Embedding/extractor
model outages degrade specific stages (backfill later), never stall persist.

## Definition of done
- INV-6 stress test: concurrent ingest on one project → seq `1..N`, no gaps/dupes.
- INV-5: duplicate + reordered deliveries → one event each; `deduplicated` reported.
- INV-13: invalid extractor output → event+memories persist, brief uncorrupted, `stale_turns` rises.
- INV-14: post-purge, zero rows in every tier for the project and empty blob prefix.
