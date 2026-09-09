# Component: pack builder

**Path:** `packages/ariadne_api/pack/` · **Kind:** module (hot path) · **Spec:** `specs/context-pack.md`

## Responsibility
Turn a state document + recall results + budget into the exact pack text the filter injects.
Deterministic, budgeted, cacheable.

## Consumes
The current `state_doc` (+ version), recall items (from `recall.py`), `budget_tokens`, the
target `model` (→ tokenizer), `UserValves.inject_mode`, and any slash-command result.

## Produces
`ContextPackResponse`: `text` (delimited markdown), `tokens`, `tokenizer`, `truncated`,
`stale_turns`, `sections[]`, `command`, `cache`.

## Key logic (all defined in `specs/context-pack.md`)
- Fixed section order; priority knapsack P0…P4; P0 (header/objective/constraints/pins/footer)
  never dropped.
- Tokenizer selected from `model`; recorded in the response and the cache key.
- Recall reserve = `min(1200, 30% budget)`; fusion `w_vec·rr + w_lex·rr + w_sal·salience`.
- Sentinels `<!-- ariadne:begin … -->` / `<!-- ariadne:end … -->`; deterministic tie-breaks only.
- Two-layer cache keyed on `(project, state_version, [budget], tokenizer, [query_hash, k])`.

## Edge cases
- Empty/near-empty project → `text=""` (filter injects nothing).
- Budget smaller than P0 → include P0 anyway, `truncated=true` (INV-9).
- Stale brief (`updated_seq` < latest event.seq) → render staleness line, set `stale_turns`.

## Failure behaviour
Pure/CPU-bound; any error bubbles to the router which returns `503` so the filter fails open. No
network calls except the recall query (already budgeted).

## Definition of done
- INV-8: golden-vector byte-equality test (`eval/pack/*.json` → `*.expected.md`), reruns identical.
- INV-9: property test over random briefs/budgets → `tokens ≤ budget ∨ truncated`; pins &
  constraints never dropped.
- Cache hit path returns byte-identical text to a cold render for the same key; `cache` field
  reports `hit|miss|bypass` correctly.
