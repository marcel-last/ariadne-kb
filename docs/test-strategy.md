# Test strategy

Ariadne has two kinds of correctness. **Deterministic** behaviour (schemas, SQL, the API
contract, pack rendering, idempotency, tenancy) is tested the normal way — asserted exactly.
**Stochastic** behaviour (what the extractor writes, whether a resumed chat actually stops
re-asking known facts) can't be asserted exactly; it's measured with an **eval harness** against
golden datasets and rubrics, and gated on a score. This file says which is which and how each is
run. It is the reference behind every "Definition of Done" bullet in `docs/component-specs/`.

The single command is `make test` (deterministic) and `make eval` (stochastic, needs model
endpoints). CI runs `make validate-kb test`; `make eval` runs on a schedule and before a release,
because it costs model calls.

## The layers (deterministic)

**1. KB contract checks — `make validate-kb`.** No app code required; runs in CI on every push.
- OpenAPI 3.1 structural validation of `openapi/*.yaml`.
- JSON-Schema well-formedness for `schemas/*.json`, plus: the five extractor examples in
  `prompts/extractor.md` apply cleanly and yield schema-valid briefs.
- Every SQL statement in `db/migrations/*.sql` parses under the real PostgreSQL grammar.
- Every markdown reference across the KB resolves (relative-to-file), forward-refs excepted.
- The `eval/pack` golden is structurally valid and within budget (see below).
This layer is what keeps the *documentation set itself* honest; it already passes today.

**2. Unit tests — `make test` (fast, no I/O).** Pure logic: the pack knapsack and section sort
keys, tokenizer selection, `content_hash` canonicalisation, JSON-Patch apply+validate, fusion
scoring, the scope-resolution ladder, JWT mint/verify. Property-based (Hypothesis) where a law is
stated — e.g. INV-9 "tokens ≤ budget ∨ truncated" over random briefs and budgets.

**3. Contract tests — `make test` (against a spec, not a running peer).** Generated from
`openapi/ariadne-api.yaml` and `openapi/ariadne-tools.yaml`: every operation's request/response
shapes and error codes, the RFC 9457 `code` enum, the `@chat:<id>` param, and — as a static
assertion — that **no** tool operation exposes a project id (INV-3). Schemathesis-style fuzzing of
the API against the spec catches shape drift.

**4. Integration tests — `make test-int` (compose stack, real Postgres + Redis + MinIO).** The
things only a real database proves:
- migrations apply on a fresh DB; `ariadne_app` cannot bypass RLS; cross-tenant read returns zero
  rows (INV-11).
- per-project `seq` is gap-free under concurrent ingest (INV-6); double-deliver ⇒ one event
  (INV-5).
- `PATCH /state` optimistic concurrency ⇒ 409 (INV-7).
- full continuity loop: inlet → pack → model stub → outlet → ingest → brief grows → next inlet
  reflects it. The Phase-1 exit test.
- `rebuild` from T0 reproduces the brief byte-for-byte (INV-2); `purge` leaves nothing (INV-14).

**5. Fault-injection tests — `make test-int`.** The fail-open invariant (INV-1) is only real if
tested adversarially: run the filter against an Ariadne that is stopped, sleeping past the 400 ms
timeout, returning 500, and returning malformed JSON; assert the chat completes and no exception
escapes the filter in every case.

## The eval harness (stochastic) — `eval/`

Run with `python eval/run.py <suite>`; see `eval/README.md`. Three suites:

- **`extraction`** — held-out `(current brief, new turn) → rubric` cases in
  `eval/extraction/cases.jsonl`. The scorer runs the extractor, then measures: **patch-validity
  rate** (fraction whose output passes `schemas/extractor-output.schema.json` *and* whose applied
  result passes `schemas/state-doc.schema.json`) and **rubric pass rate** (did the patch touch the
  paths it should, mark the right states, and never touch `/pins`,`/meta`,`/schema`; did a memory
  mention the required fact). Cases are **held out** from the prompt's few-shots — never score on
  training examples. Gate: patch-validity ≥ 0.98, rubric ≥ 0.90 (tune in `eval/README.md`).
- **`pack`** — the deterministic golden in `eval/pack/`. Not stochastic, but lives here because it
  is a fixture suite: render the input, normalise the volatile pack-id token, and assert
  byte-equality with `eval/pack/recon-acme.expected.md`, plus `tokens ≤ budget` and `truncated == false`
  (INV-8, INV-9). Any intentional rendering change updates the golden in the same commit — that
  diff is the human review signal (`specs/context-pack.md` §9).
- **`resume`** — scenario suite in `eval/resume/scenarios.jsonl`: seed a brief, open a *fresh*
  chat, inject the pack, ask a question, and score whether the model **surfaces** known facts and
  does **not re-ask** things the pack already contains. This is the end-user promise (goal G1)
  turned into a number: *resume-success rate*. Needs a model in the loop; report per-model.

### Why rubrics, not exact match, for extraction
Two correct extractions of the same turn can differ in wording, id choice, or whether a fact goes
to `state_patch` vs `memories`. Asserting exact JSON would make the test flaky and the prompt
un-improvable. Rubrics assert the **properties that must hold** (a finding got marked `confirmed`;
no pin was touched) and leave the rest free. The one exact-match check is the pack golden, which
*is* deterministic by design.

## Fixture policy
- **Recorded > written.** Platform fixtures (`fixtures/openwebui/`) must come from a real Open
  WebUI instance; the ones shipped now are documented reference shapes to be replaced by captures
  (see that folder's README). Contract tests run against the captured versions.
- **Redact before commit.** No real user ids, emails, hostnames, or secrets in any fixture.
- **Golden diffs are review gates.** A changed `*.expected.md` or a moved gate threshold must be
  an explicit, reviewed line in the diff — never auto-regenerated silently in CI.
- **Secrets never in fixtures.** Abuse-case fixtures that *simulate* a leaked secret use an
  obvious fake token and assert it is absent downstream; they never embed a real one.

## Invariant → test map
Every invariant in `docs/INVARIANTS.md` has at least one home here. Quick index:

| Invariant | Where tested |
|---|---|
| INV-1 fail-open | fault-injection (layer 5) |
| INV-2 rebuild = projection | integration: rebuild byte-equality |
| INV-3 no model project id | contract (static) + tools integration; `security/abuse-cases.md` |
| INV-4 pins/meta immutable | unit (patch validate) + extraction rubric |
| INV-5 idempotent ingest | integration: double-deliver |
| INV-6 gap-free seq | integration: concurrent ingest |
| INV-7 optimistic concurrency | integration: 409 on stale base_version |
| INV-8 deterministic pack | eval `pack` golden |
| INV-9 budget respected | unit property test + eval `pack` |
| INV-10 no secrets stored | `security/abuse-cases.md` cases |
| INV-11 tenant isolation | integration: RLS cross-tenant |
| INV-12 short-lived identity | unit: JWT verify |
| INV-13 extraction never blocks | integration: bad extractor output |
| INV-14 purge complete | integration: post-purge emptiness |

If a change touches an area, run that row before calling it done.
