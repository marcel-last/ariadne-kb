# ADR-0010: Constrain the extractor to a schema-validated patch envelope

**Status:** Accepted

## Context
Extraction is the highest-variance component: a small LLM turning a turn into durable state. Left
unconstrained it will occasionally emit prose, malformed JSON, oversized edits, or writes to
forbidden fields — any of which could corrupt the brief or stall ingestion.

## Decision
The extractor must emit exactly one JSON object matching `schemas/extractor-output.schema.json`: a bounded
`state_patch` (allowed roots only, ≤ 40 ops), bounded `memories` (self-contained, ≤ 30), an
optional `segment_boundary` and `notes_for_reviewer`. Use JSON-mode / grammar-constrained decoding.
The worker validates against this schema, applies the patch, then re-validates the result against
the state schema.

## Alternatives rejected
- **Trust freeform model output and parse leniently** — unbounded failure modes, silent corruption.
- **No memories, state-only** — loses individually-retrievable recall (T3) and supersession hints.

## Consequences
- Two-stage validation (envelope, then applied result) with a defined failure ladder: retry once,
  keep memories if the patch is rejected, never block ingest (INV-13).
- Forbidden-path guard in the schema pattern enforces pin/meta immutability at the earliest point
  (INV-4).
- Prompt changes here usually require a `rebuild` and a re-run of `eval/extraction` (Tier 5);
  patch-validity rate is the gating metric.

## Produces / relates to
INV-4, INV-13 · `schemas/extractor-output.schema.json`, `prompts/extractor.md`, `schemas/state-doc.schema.json`
