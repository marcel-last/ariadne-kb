# ADR-0003: Maintain the brief by validated JSON-Patch, not full replace

**Status:** Accepted

## Context
The brief (T1) changes a little each turn. The extractor is an LLM; letting it re-emit the whole
document invites drift, accidental deletions, and pin/rule violations, and makes concurrent edits
unresolvable.

## Decision
The extractor emits a **constrained RFC 6902 patch** (plus memories); the worker applies it with
optimistic concurrency and re-validates the *result* against `schemas/state-doc.schema.json`. Only the
mutable roots are patchable; `/pins`, `/meta`, `/schema` are off-limits to non-user authors.

## Alternatives rejected
- **Full-document rewrite by the model** — high-variance, unbounded blast radius, no natural
  supersession, and no way to protect pins.
- **Freeform natural-language state** — not queryable, not budgetable, not testable.

## Consequences
- Small, auditable diffs with per-version history (`state_doc_history`) and non-destructive
  restore.
- Requires a strict output contract (ADR-0010) and post-apply validation.
- Concurrent writers are handled by `base_version` → `409` (INV-7); a rejected patch keeps the
  memories and defers T1 (INV-13).
- Pins/meta immutability is enforceable and testable (INV-4).

## Produces / relates to
INV-4, INV-7, INV-13 · `schemas/state-doc.schema.json`, `schemas/extractor-output.schema.json`, `prompts/extractor.md`
