# Ariadne — knowledge base

External conversation-state / memory service for Open WebUI. This repository is the
**source-of-truth knowledge base** an implementation (human or AI agent) builds against.
Start with `docs/architecture.md` for the *why*; the files below are the *contracts*.

> Codename **Ariadne** is a placeholder — rename freely; it appears only in prose, not in
> schema `$id`s that matter for runtime (those can be namespaced at build time).

## Tier 1 — contracts (this drop)

Everything here is machine-checkable and has been validated (OpenAPI 3.1 structure, JSON
Schema draft 2020-12, and every SQL statement parsed by the PostgreSQL grammar via
libpg_query; the five extractor examples apply cleanly and produce schema-valid state).

| Path | What it is | Consumer |
|---|---|---|
| `openapi/ariadne-api.yaml` | Full service API (pack, turns, projects, state, memory, sessions, jobs, ops). RFC 9457 errors. | server, clients, contract tests |
| `openapi/ariadne-tools.yaml` | Model-facing tool surface registered in Open WebUI. **No op takes a project id** — resolved from the forwarded chat id. | the model, Open WebUI |
| `schemas/state-doc.schema.json` | `ariadne.state/1` — the working-state "brief". Enforced at runtime on every patch. | api, worker |
| `schemas/extractor-output.schema.json` | The constrained JSON-Patch envelope the extractor LLM must emit. | worker (extract stage) |
| `prompts/extractor.md` | The extractor system prompt + user template + 5 validated few-shot examples + failure handling. | worker (extract stage) |
| `db/migrations/0001…0006_*.sql` | PostgreSQL 17 + pgvector schema (16 tables, RLS, per-project seq, hybrid-search indexes). | database |
| `db/README.md` | Roles, running migrations, tenant GUC, embedding dim, what is safe to drop. | operators |
| `specs/context-pack.md` | Deterministic pack rendering, priority-knapsack budget, tokenizer, caching, slash commands, injection modes. | api (pack builder) |
| `specs/queue-messages.md` | Redis Streams payloads, stage pipeline, idempotency, ordering/locking, DLQ, backpressure. | api, worker |
| `docs/architecture.md` | The full architecture document, with the section-5 integration diagrams. | everyone |
| `docs/diagrams/` | Rendered PNGs + Mermaid sources for the integration touchpoints. | everyone |

## Invariants you will see referenced

These are stated as enforceable properties in `docs/INVARIANTS.md` (INV-1…14), each mapped to a
mechanism and a test:

1. **Ariadne never breaks a chat** — the filter fails open; a pack is best-effort.
2. **T0 (`event`) is the only source of truth** — T1/T2/T3 are rebuildable projections.
3. **The model never supplies a `project_id`** — binding is server-derived (chat id → project).
4. **Pins and `meta` are immutable to the extractor** — only `user`/`tool` authors touch pins.
5. **Every write is idempotent** — turns on `(project_id, content_hash)`; stages on `stage_cursor`.

## Tier 2 — platform reference (Open WebUI facts)

Platform facts that a model's training data will be stale on, pinned to a version with cited
sources. Verified against the official Open WebUI docs on 2026-09-09 (Open WebUI 0.11.x).

| Path | What it is | Consumer |
|---|---|---|
| `docs/open-webui-integration.md` | Filter pipeline (inlet/request/stream/outlet), dunder params, `__metadata__` correlation, keys popped after inlet, fail-open reality, `outlet`-on-API gotcha, tool-server headers + `ENABLE_FORWARD_USER_INFO_HEADERS`, Native-vs-Legacy default and the detection trap. Ends with a decision ledger and a live-verify list. | filter, tools, reconciler |
| `fixtures/openwebui/*.json`, `tool-request.http` | Reference **shapes** for inlet/outlet bodies, `__metadata__`, `__user__`, the tool HTTP request, and a status event — with a probe-filter recipe to replace them with real captures. | contract/unit tests |
| `fixtures/openwebui/README.md` | Provenance (these are derived-from-docs, not live captures) + the capture recipe. | everyone |

> The fixtures are honest scaffolding: correct at the structural level, but two fields are
> marked `VERIFY:` because the docs don't fully pin them (`folder_id` location; whether user
> headers reach external tool servers). Capture ground truth before the resolver is "done".

## Tier 3 — decisions, invariants, vocabulary

The rules an implementer must not relitigate or violate, plus the shared vocabulary they're
written in. Every invariant maps to a mechanism in the Tier 1/2 files and a test; every ADR
links to the invariant(s) it produces. Cross-references verified to resolve.

| Path | What it is | Consumer |
|---|---|---|
| `docs/INVARIANTS.md` | 14 non-negotiable properties (INV-1…14), each as a testable statement with its enforcement mechanism, a concrete check, and the ADR behind it. Tagged `[SAFETY]`/`[CORRECTNESS]`/`[QUALITY]`. | everyone; reviewers |
| `docs/adr/` | 10 architecture decision records (0001–0010): store, integration, patch-not-replace, fail-open, server-derived binding, T0-as-truth, native function calling, mandatory reconciler, Redis Streams, constrained extractor. Each with alternatives rejected + consequences. | everyone |
| `docs/adr/README.md` | ADR index + status legend. | everyone |
| `docs/GLOSSARY.md` | One definition per term (scopes, tiers, moving parts, ingestion, state, cross-cutting), each mapped to its table/schema/endpoint. Read this first. | everyone |

> Reading order: `docs/GLOSSARY.md` → `docs/architecture.md` → the relevant ADR → `docs/INVARIANTS.md` for the
> properties your component must uphold.

## Tier 4 — agent working instructions

What an implementer (human or coding agent) reads to build the thing: the entry-point rules, one
contract per component, and a phased task list where every task has a test-provable acceptance
criterion. All references verified to resolve.

| Path | What it is | Consumer |
|---|---|---|
| `CLAUDE.md` | Entry point read every session: repo layout, hard rules (the invariants condensed), explicit "do not"s, conventions (async Python, RFC 9457 errors, config, logging), run/test/lint, and the definition of done for any task. ~100 lines, links out. | the coding agent |
| `AGENTS.md` | Cross-tool pointer to `CLAUDE.md` (no separate content). | non-Claude agents |
| `docs/component-specs/` | One spec per module (common, api, pack-builder, worker, tools, reconciler, filter): responsibilities, interfaces, failure behaviour, and a Definition of Done whose every line is an invariant check or contract test. | per-component work |
| `BACKLOG.md` | Phases 0–4 broken into agent-sized tasks, each naming its component spec and the invariant(s) it must uphold, with acceptance criteria a test can prove. | planning, execution |

> Start at `CLAUDE.md` → read the component spec for your module → work the next `BACKLOG.md`
> task → prove its acceptance criteria and the spec's Definition of Done.

## Tier 5 — testing & evaluation (the quality loop)

Turns the "Definition of Done" checks the earlier tiers promise into runnable fixtures. The
`eval/` harness self-validates offline against the real schemas today (`python eval/run.py all`).

| Path | What it is | Consumer |
|---|---|---|
| `docs/test-strategy.md` | The five deterministic layers (KB checks, unit, contract, integration, fault-injection) + the stochastic eval loop + fixture policy, with an invariant→test map covering all 14. | everyone |
| `eval/run.py` | Harness: offline it validates every fixture against `schemas/`, recomputes the golden pack's heuristic tokens, and checks rubrics/scenarios; `--live URL` exercises the built system. | CI, developers |
| `eval/pack/recon-acme.json` + `.expected.md` | The deterministic pack golden (INV-8/INV-9). Heuristic tokenizer so it reproduces offline; pack-id token normalised before diff. | pack builder |
| `eval/extraction/cases.jsonl` | Six held-out extractor cases with property rubrics (patch-validity + rubric pass; gate 0.98 / 0.90). | extractor |
| `eval/resume/scenarios.jsonl` | Resume-success scenarios (surface known facts, don't re-ask) — goal G1 as a number. | end-to-end |
| `security/abuse-cases.md` | Eight concrete attacks (AC-1…8) — transcript injection, model-names-a-project, forged chat id, secret-in-transcript, cross-tenant recall, poisoned memory, pack injection, exhaustion — each with defence, invariant, and a test. | security work; BACKLOG 4.3 |

> Everything here is validated: 8 abuse cases cite only real invariants and each has all five
> fields; the test-strategy maps every INV-1…14; the golden and all JSONL fixtures pass
> `eval/run.py` against the actual schemas.

## Tier 6 — operations

Everything needed to run the thing, and the last tier to close every forward reference in the KB.

| Path | What it is | Consumer |
|---|---|---|
| `docs/config-reference.md` | Every env var, Valve/UserValve, and per-project policy flag — 42 documented keys — with default, which component reads it, and a "must match elsewhere" consistency list. Defaults verified to agree with the specs. | operators, every component |
| `docs/runbook.md` | Bring-up, Open WebUI registration, day-2 procedures (rebuild/merge/export/purge/checkpoint), the metric set and what each means, alerts→responses (all under the fail-open posture), backup/restore, upgrades, and an incident quick-reference. | operators |

## Status: complete

All six tiers are present and cross-validated. `python eval/run.py all` and the KB contract
checks pass; every documentation reference across the KB resolves (no remaining forward
references); config defaults agree with the specs; and the Tier-1 machine-readable contracts
(OpenAPI, JSON Schema, SQL) all validate. Point a coding agent at `CLAUDE.md` and work
`BACKLOG.md` from Phase 0.

## Validation

Re-run the Tier-1 checks (needs `pip install jsonschema openapi-spec-validator pglast jsonpatch pyyaml`):

```bash
# OpenAPI structure
python -c "from openapi_spec_validator import validate; from openapi_spec_validator.readers import read_from_filename as r; import copy; s,_=r('openapi/ariadne-tools.yaml'); validate(s); print('tools OK')"
# JSON Schemas well-formed
python -c "import json; from jsonschema import Draft202012Validator as V; [V.check_schema(json.load(open(p))) for p in ('schemas/state-doc.schema.json','schemas/extractor-output.schema.json')]; print('schemas OK')"
# SQL parses under the real PG grammar
python -c "import glob,pglast; [pglast.parse_sql(open(f).read()) for f in glob.glob('db/migrations/*.sql')]; print('migrations OK')"
```
