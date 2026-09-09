# ADR-0006: The T0 event log is the single source of truth

**Status:** Accepted

## Context
Several derived structures (brief, summaries, memory index) are produced by LLMs and embeddings,
which change over time. We need recoverability, auditability, and the freedom to re-index without
data loss.

## Decision
The append-only `event` table (T0) is authoritative. T1 (brief), T2 (summaries) and T3 (memory)
are **projections** rebuildable by replaying events. A `rebuild` job regenerates them
deterministically; `merge` replays one project's events into another.

## Alternatives rejected
- **Treat the brief as primary and the log as optional** — makes prompt/model upgrades destructive
  and loses the audit trail.
- **No event log, mutate projections in place** — unrecoverable from extraction bugs.

## Consequences
- Anything except T0 (and the identity tables) can be truncated and rebuilt (`db/README.md`).
- Rebuild must be deterministic for a fixed extractor/embedding version (INV-2).
- Per-project gap-free `seq` (INV-6) defines replay order and summary boundaries.
- Purge must delete T0 too, and is irreversible (INV-14).

## Produces / relates to
INV-2, INV-6, INV-14 · `db/migrations/0002_events.sql`, `openapi/ariadne-api.yaml` (`/rebuild`, `/merge`, `/export`)
