# ADR-0001: Postgres 17 + pgvector as the store

**Status:** Accepted

## Context
Ariadne needs, per project: an append-only event log, a versioned JSON document, hierarchical
summaries, a semantic + lexical memory index, artifact metadata, jobs, and hard multi-tenant
isolation. A self-hostable single-binary-ish dependency footprint matters (goal G7). The
retrieval need is hybrid (vector ANN **and** full-text), not vector-only.

## Decision
Use **PostgreSQL 17** as the primary store, with **pgvector** for embeddings and native
`tsvector` for lexical search. Redis is the cache / queue / lock layer; an S3-compatible object
store (MinIO) holds artifact blobs. Build the *memory model* ourselves; *rent* the storage.

## Alternatives rejected
- **A dedicated vector DB (Qdrant/Weaviate/…)** — adds a second stateful system and still leaves
  relational data, transactions and RLS to Postgres. Vector search is not the hard part; the
  relational integrity and tenancy are. Kept as a documented later escape hatch if ANN scale
  demands it.
- **SQLite + sqlite-vec** — attractive for a single-user desktop variant and offered as such, but
  no real concurrency, RLS, or advisory locks for the per-project sequence.
- **A bespoke store** — throws away transactions, backup tooling, and RLS for no benefit.

## Consequences
- One stateful system to operate, back up and reason about; RLS gives defence-in-depth tenancy
  (INV-11) and advisory locks give the gap-free per-project `seq` (INV-6).
- Embedding dimension is fixed at the column (`vector(1024)`); changing models needs a migration
  + re-embed (`db/README.md`).
- The HNSW index is partial (`WHERE valid AND embedding IS NOT NULL`) to stay small.
- If single-tenant ANN volume outgrows pgvector, ADR-supersede with an external ANN index while
  keeping Postgres authoritative.

## Produces / relates to
INV-6, INV-11 · `db/migrations/*.sql`, `db/README.md`
