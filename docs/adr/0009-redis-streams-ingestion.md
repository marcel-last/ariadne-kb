# ADR-0009: Redis Streams for the ingestion queue

**Status:** Accepted

## Context
`/v1/turns` must return in tens of milliseconds (ADR-0004) and hand off to asynchronous stages
(persist → embed → extract → summarize) with at-least-once delivery, per-project ordering, retries
and a dead-letter path. Redis is already the cache/lock layer.

## Decision
Use **Redis Streams** with consumer groups: `ariadne:ingest` for turns, `ariadne:jobs` for
long-running operations, `ariadne:dlq` for poison messages. Reclaim stuck entries with
`XAUTOCLAIM`; track per-project/per-stage progress in `stage_cursor`. Contract in
`specs/queue-messages.md`.

## Alternatives rejected
- **Celery / RQ** — heavier, and we'd still design our own idempotency and ordering; Streams give
  consumer groups and PEL reclaim natively.
- **RabbitMQ / Kafka** — another stateful system to run for a self-hostable tool; overkill at this
  scale.
- **A Postgres-based queue (SKIP LOCKED)** — viable, but couples queue throughput to the primary
  DB and duplicates what Redis already gives us here.

## Consequences
- Redis is not a source of truth: on `XADD` failure the API persists the event inline so a turn is
  never lost (degraded, not dropped); the stream can be trimmed once turns are in Postgres.
- Per-project ordering uses a Redis lock with a Postgres advisory-lock fallback; `UNIQUE(project_id,
  seq)` is the ultimate backstop (INV-6).
- Stages are independent and idempotent so at-least-once yields effectively-once effects (INV-5,
  INV-13).

## Produces / relates to
INV-5, INV-6, INV-13 · `specs/queue-messages.md`, `db/migrations/0005_artifacts_jobs.sql`
