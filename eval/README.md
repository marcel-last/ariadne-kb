# eval/

Golden datasets and a harness for the parts of Ariadne that can't be asserted exactly. See
`docs/test-strategy.md` for how this fits the whole test picture. Three suites:

| Suite | What it measures | Deterministic? |
|---|---|---|
| `pack` | the context pack renders exactly as specified, within budget (INV-8, INV-9) | yes (golden) |
| `extraction` | the extractor emits valid, correct patches/memories (patch-validity, rubric) | no (scored) |
| `resume` | a resumed chat surfaces known facts and doesn't re-ask them (goal G1) | no (scored) |

## Running

```bash
python eval/run.py all              # OFFLINE: validate every fixture (what CI runs)
python eval/run.py pack             # one suite
python eval/run.py extraction --live http://localhost:8080   # also exercise the running system
```

Offline mode needs only `jsonschema` and validates fixtures against the **real** schemas in
`schemas/`, recomputes the golden pack's heuristic token count, and checks every rubric/scenario
is well-formed. Live mode additionally calls the built system (hooks marked `TODO(live)` in
`run.py` until the components exist).

## `pack/` — the deterministic golden

- `pack/recon-acme.json` — input: a schema-valid `state_doc`, the `recall` items, and the
  `request` (`budget_tokens`, `tokenizer`, `query`).
- `pack/recon-acme.expected.md` — the exact bytes the pack builder must produce.

The tokenizer is **`heuristic`** (`ceil(chars/4 * 1.1)`) so the vector is reproducible offline
with no BPE-vocab download. Add a parallel `pack/recon-acme.o200k.expected.md` where the `o200k_base`
vocab is available. The pack carries a per-call **pack id** in its sentinels; that value is *not*
deterministic, so the live check **normalises** the `pack=<uuid>` token to `pack=<pack_id>` before
diffing — everything else must match byte-for-byte. Any intentional rendering change updates the
golden in the same commit; that diff is the review signal (`specs/context-pack.md` §9).

## `extraction/cases.jsonl` — held-out extractor cases

One JSON object per line. Cases are **held out** from the few-shot examples in
`prompts/extractor.md` — never score on training examples. Each case:

```jsonc
{
  "id": "ex-h4-finding-remediated",
  "current_doc": { /* brief excerpt; completed to a valid doc before the run */ },
  "turn": "user: ...\nassistant: ...",
  "rubric": {
    "expect_empty_patch": false,               // the turn changes nothing durable
    "patch_must_touch": ["/findings/0/state"], // at least these op paths appear
    "patch_must_not_touch": ["..."],           // in addition to the always-forbidden set
    "state_result": {"path":"/findings/0/state","equals":"remediated"}, // applied-doc assertion
    "new_array_item": {"path":"/open_threads","fields":{"status":"open"}}, // an added item's fields
    "memories_must_mention": ["remediat"],     // >=1 memory contains each substring
    "memories_must_be_empty": true,            // no memories
    "memories_may_be_empty": true,             // memories optional (don't penalise absence)
    "must_not_appear_anywhere": ["AKIA-..."],  // secret value absent from patch AND memories (INV-10)
    "notes_for_reviewer_expected": true        // a scope/constraint change was flagged
  }
}
```

The always-forbidden paths `/pins`, `/meta`, `/schema` are enforced for **every** case regardless
of rubric (INV-4); a case may not ask to touch them.

**Scoring (live):** for each case, `valid` = the output matches
`schemas/extractor-output.schema.json` **and** the applied brief matches
`schemas/state-doc.schema.json`; `rubric_pass` = every rubric clause holds. Report
**patch-validity rate** and **rubric pass rate**.
**Gate:** patch-validity ≥ 0.98, rubric ≥ 0.90. Tune here as the extractor model changes; a
prompt change that needs the gate lowered is a regression to discuss, not to rubber-stamp.

## `resume/scenarios.jsonl` — resume-success benchmark

One JSON object per line: a `seed_state` (a valid brief), a `fresh_question` asked in a brand-new
chat, the facts the answer `must_surface`, and the things it `must_not_reask` (because the pack
already contains them). The runner builds a pack from `seed_state`, injects it, asks the question,
and scores the model's answer.

**Score:** *resume-success rate* = fraction of scenarios where all `must_surface` facts appear and
no `must_not_reask` item is asked back. Report per model — this is the end-user promise (G1) as a
number, and the honest way to compare candidate chat models.

## Adding cases
- Keep extraction cases **held out** and small; one behaviour per case.
- Redact anything real. Secret-exclusion cases use an obvious fake token and assert its absence.
- A new golden or a moved gate threshold is a reviewed line in the diff — never regenerated
  silently.
