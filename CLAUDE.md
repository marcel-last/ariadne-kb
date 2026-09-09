# CLAUDE.md — working instructions for building Ariadne

You are implementing **Ariadne**, an external conversation-state / memory service for Open WebUI.
This file is your entry point every session. It is short on purpose; it tells you where to look
and what you must not break. Read the linked files for detail rather than guessing.

## What Ariadne is (one paragraph)
Ariadne moves long-lived chat state out of the prompt into a service. On each turn an Open WebUI
**filter** asks Ariadne for a small, budgeted **context pack** and injects it, then ships the
completed **turn** back. Ariadne keeps, per **project**: an append-only event log (T0, the source
of truth), a versioned **brief** (T1), summaries (T2), a searchable memory index (T3) and
artifacts (T4). A new or cleared chat resumes at fixed token cost. Full rationale:
`docs/architecture.md`.

## Read these before writing code
1. `docs/GLOSSARY.md` — the vocabulary. Use these exact nouns.
2. `docs/INVARIANTS.md` — the 14 properties you must not break. **Non-negotiable.**
3. `docs/adr/` — why each major choice was made. Don't relitigate; if you must change one, edit
   the ADR's status and write a superseding one first.
4. The contract for whatever you're touching: `openapi/*.yaml`, `schemas/*.json`,
   `specs/*.md`, `db/migrations/*.sql`, `docs/open-webui-integration.md`.
5. The component spec for your module: `docs/component-specs/`.

## Repo layout
```
packages/
  ariadne_common/       shared: config, db(+tenant GUC), redis, auth(JWT), schema validation, models
  ariadne_api/          HTTP service; routers/, scope.py, recall.py, pack/ (pack builder), errors.py
  ariadne_worker/       Redis-Streams consumer; stages/ persist,embed,extract,summarize; jobs/
  ariadne_tools/        model-facing OpenAPI tool server (proxies to api via @chat:<id>)
  ariadne_reconciler/   periodic backfill of turns outlet missed
integrations/openwebui/
  filter/ariadne_filter.py   the Open WebUI filter — ONE self-contained file, no repo imports
  fixtures/                  recorded/reference OWUI payloads (see fixtures/openwebui/)
docs/  specs/  openapi/  schemas/  prompts/  db/   ← the knowledge base (contracts live here)
tests/ unit/ contract/ integration/     eval/ extraction/ pack/     deploy/compose/
```
Services communicate over **HTTP and Redis only** — they never import each other. Everything
shared goes through `ariadne_common`. The filter imports nothing from this repo.

## Hard rules (violating these is a defect, not a style nit)
- **Never put Ariadne in a chat's critical path.** The filter fails open: ≤400 ms timeout,
  try/except, return `body` unchanged on any error. (INV-1 / ADR-0004)
- **T0 is the only source of truth.** Never make a projection (T1/T2/T3) the sole home of a fact;
  everything must be rebuildable from `event`. (INV-2 / ADR-0006)
- **The model never supplies a project id.** `ariadne-tools` has no project parameter; resolve
  from `X-OpenWebUI-Chat-Id`; unbound ⇒ 428 fail-closed. (INV-3 / ADR-0005)
- **Never let the extractor touch `/pins`, `/meta`, `/schema`.** Enforced by the extractor output
  schema + author check. (INV-4 / ADR-0003)
- **Every turn write is idempotent** on `(project_id, content_hash)`. (INV-5)
- **Set the tenant GUC** (`SET LOCAL ariadne.tenant`) from the *verified* claim on every
  tenant-scoped query — never from request input. (INV-11, INV-12)
- **Never store secrets** in brief/memory/embeddings; reference-only. (INV-10)

## Do NOT
- Do **not** hand-roll a datastore, cache, or vector index — use Postgres+pgvector and Redis as
  specified (ADR-0001). Don't add a new stateful dependency without an ADR.
- Do **not** `eval`/`exec` extractor output or trust it unvalidated — it's an LLM; validate against
  `schemas/extractor-output.schema.json`, then re-validate the applied brief. (ADR-0010)
- Do **not** skip schema validation "for now". The schemas are runtime contracts, not docs.
- Do **not** import `ariadne_*` packages into the filter, or import one service into another.
- Do **not** widen the tool surface with anything that takes a project/tenant/user id.
- Do **not** invent Open WebUI behaviour from memory — check `docs/open-webui-integration.md`
  (pinned) and, where it says `VERIFY:`, the fixtures.

## Conventions
- **Python 3.12+, fully async** (`asyncpg`, `httpx`, `redis.asyncio`). Type-annotate everything;
  `mypy --strict` clean. Pydantic v2 models, sourced from the OpenAPI where possible.
- **Errors:** raise typed errors from `ariadne_common`; the API maps them to RFC 9457
  `problem+json` with the stable `code` enum in `openapi/ariadne-api.yaml`. Cross-tenant misses
  are `404`, never `403`.
- **Config:** only through `ariadne_common.config`; every knob is in `docs/config-reference.md`
  (Tier 6). No bare `os.environ`.
- **Logging:** structured (JSON), one event per stage transition, include `project_id`/`seq`/
  `trace_id`; never log secrets or full message bodies at info level.
- **Migrations:** forward-only, `dbmate`, in `db/migrations/`; never edit an applied migration.
- **Determinism where promised:** the pack (INV-8) and rebuild (INV-2) must be byte-reproducible;
  no wall-clock, RNG, or map-order in their output.

## How to run / test / lint
```bash
make up           # compose: postgres17+pgvector, redis, minio, api, worker, tools
make migrate      # dbmate up  (see db/README.md for roles/bootstrap)
make test         # unit + contract + integration
make lint         # ruff + mypy --strict
make validate-kb  # re-run the Tier-1/2/3 contract & reference checks (below)
```
`make validate-kb` runs: OpenAPI validation of `openapi/*.yaml`; JSON-Schema well-formedness +
the extractor examples applying cleanly; every SQL statement parsed by the PG grammar; and the
markdown cross-reference check. Keep it green.

## Definition of done for ANY task
1. The relevant contract test (generated from the OpenAPI / validated against the schemas) passes.
2. The **Definition of Done** bullets in your component spec (`docs/component-specs/<x>.md`) pass —
   each maps to an INV check.
3. No invariant in `docs/INVARIANTS.md` regresses (run its Check for anything you touched).
4. `make lint` and `make validate-kb` are green.
5. If you changed a decision or an interface, the ADR / OpenAPI / schema is updated in the same
   change — code and contract never diverge.

When in doubt, prefer the smallest change that satisfies the contract and keeps the invariants,
and leave a note in the task's PR pointing at the spec section you relied on.
