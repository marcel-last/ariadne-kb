# Architecture decision records

Each ADR captures **one** decision: the context that forced it, what was chosen, what was
rejected and why, and the consequences that follow. They exist so an implementer (human or
agent) does not silently relitigate a settled choice or violate the invariant it produced. If
you believe a decision is wrong, don't quietly diverge — change the ADR's status and write the
superseding one.

**Status values:** `Proposed` · `Accepted` · `Superseded by ADR-nnnn` · `Deprecated`.

Every ADR links to the invariant(s) in `../INVARIANTS.md` it produces and the Tier-1/2 files
that implement it. The condensed decision list in `docs/architecture.md` §11 is the source these
expand on.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-postgres-pgvector-store.md) | Postgres 17 + pgvector as the store (rent storage, build the memory model) | Accepted |
| [0002](0002-integrate-via-filter.md) | Integrate via an Open WebUI Filter function (not Pipelines/CDC/native memory) | Accepted |
| [0003](0003-state-as-json-patch.md) | Maintain the brief by validated JSON-Patch, not full replace | Accepted |
| [0004](0004-fail-open.md) | Fail open — Ariadne is never in a chat's critical path | Accepted |
| [0005](0005-server-derived-project-binding.md) | Server-derived project binding + two-header auth; the model never names a project | Accepted |
| [0006](0006-event-log-source-of-truth.md) | The T0 event log is the single source of truth; T1–T3 are projections | Accepted |
| [0007](0007-require-native-function-calling.md) | Require Open WebUI Native function calling for the tool surface | Accepted |
| [0008](0008-reconciler-mandatory.md) | Turn capture is best-effort `outlet` + a mandatory reconciler | Accepted |
| [0009](0009-redis-streams-ingestion.md) | Redis Streams for the ingestion queue (not Celery/RabbitMQ/DB-queue) | Accepted |
| [0010](0010-extractor-constrained-output.md) | Constrain the extractor to a schema-validated patch envelope | Accepted |
