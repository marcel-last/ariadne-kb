# Backlog

Work broken into agent-sized tasks. Each task has **acceptance criteria a test can prove** —
if you can't write the test, the task isn't specified well enough yet. Tasks name the component
spec and invariant(s) they serve. Do phases in order; within a phase, respect the `needs`.

Legend: `[INV-n]` an invariant the task must uphold · `→ spec` the authoritative reference.

---

## Phase 0 — Skeleton & guardrails
*Goal: an empty but wired system that comes up, migrates, and enforces the KB checks in CI. No
features yet.*

- **0.1 Repo scaffold.** Create the `packages/*`, `integrations/`, `tests/`, `eval/`,
  `deploy/compose/` layout from `CLAUDE.md`; `pyproject.toml` workspace; `make` targets.
  *Accept:* `make lint` runs (empty pass); `make validate-kb` green on the existing KB.
- **0.2 Compose stack.** Postgres 17 + pgvector, Redis, MinIO, plus empty `api`/`worker`/`tools`
  containers. → `db/README.md`. *Accept:* `make up` healthy; `psql` reaches the DB; `redis-cli
  ping`.
- **0.3 Migrations run for real.** Apply `db/migrations/0001–0006` with `dbmate`; create
  `ariadne_migrate` / `ariadne_app` roles. → `db/README.md`. *Accept:* all 6 apply on a fresh DB;
  `ariadne_app` is non-superuser and **cannot** bypass RLS (test: a row of tenant B is invisible
  under `ariadne.tenant=A`) `[INV-11]`.
- **0.4 `ariadne_common` foundations.** config, db pool w/ tenant GUC, redis, auth mint/verify,
  schema loaders. → `docs/component-specs/common.md`. *Accept:* the common DoD tests pass `[INV-11,
  INV-12, INV-4]`.
- **0.5 Health + CI.** `/healthz`, `/readyz` (checks Postgres/Redis/migrations); CI runs
  `make validate-kb test lint`. *Accept:* `/readyz` flips false when a dep is down; CI blocks a
  merge that reddens `validate-kb`.

## Phase 1 — Minimal continuity loop (the core value)
*Goal: a chat can `/resume` a project and get a pack; turns are captured and persisted; the brief
grows. Single-user, no recall yet.*

- **1.1 Auth + tenancy middleware (api).** Two-header auth; set tenant GUC per request; RFC 9457
  errors. → `docs/component-specs/api.md`. *Accept:* expired/bad claim ⇒ 401; body-supplied ids can't
  override header-derived ones `[INV-12]`.
- **1.2 Projects + sessions CRUD.** `POST/GET/PATCH /v1/projects`, `/v1/sessions/{chat}/bind`. 
  *Accept:* contract tests pass; slug conflict ⇒ 409 `slug_conflict`.
- **1.3 Scope resolution ladder (`scope.py`).** existing → command → folder → default → implicit;
  record `bound_by`; accept `@chat:<id>`. → `docs/component-specs/api.md`. *Accept:* each rung selected
  under the right inputs; a model-facing `@chat:` with no binding fails closed `[INV-3]`.
- **1.4 Ingest endpoint + persist stage.** `POST /v1/turns` (202/inline-fallback) →
  `ariadne:ingest` → `persist` assigns `seq`, inserts `event`. → `docs/component-specs/worker.md`,
  `specs/queue-messages.md`. *Accept:* double-deliver ⇒ one event, `deduplicated:true` `[INV-5]`;
  concurrent ingest ⇒ gap-free `seq` `[INV-6]`.
- **1.5 Extractor (extract stage), state PATCH, history.** Run `prompts/extractor.md`; validate
  envelope; apply patch w/ `base_version`; write `state_doc(+history)`. → `docs/component-specs/worker.md`,
  ADR-0003/0010. *Accept:* the 5 few-shot examples produce schema-valid briefs; forbidden-path
  patch rejected `[INV-4]`; stale `base_version` ⇒ 409 `[INV-7]`; invalid extractor output ⇒
  event kept, brief uncorrupted `[INV-13]`.
- **1.6 Pack builder (P0/P1 only).** Render header/objective/constraints/pins + core state within
  budget; sentinels; tokenizer; determinism. → `docs/component-specs/pack-builder.md`,
  `specs/context-pack.md`. *Accept:* golden vector byte-equality `[INV-8]`; `tokens ≤ budget ∨
  truncated`, pins/constraints never dropped `[INV-9]`.
- **1.7 The filter (inlet+outlet).** Fetch+inject pack; stash correlation; ship turn
  fire-and-forget; UserValves; fail open. → `docs/component-specs/filter.md`,
  `docs/open-webui-integration.md`. *Accept:* fault-injection — Ariadne down/slow/500/bad-JSON ⇒
  chat still completes `[INV-1]`; re-injection doesn't stack; correlation round-trips.
- **1.8 Slash commands.** `/resume`, `/project new|list|rename`, `/pin`, `/state`,
  `/checkpoint`, `/restore`. → `specs/context-pack.md` §6. *Accept:* command stripped when
  `strip=true`; `/pin` writes a pin the extractor can't later touch `[INV-4]`.

**Phase-1 exit:** open a fresh chat, `/resume <slug>`, and the model correctly answers "where did
we leave off" from the injected pack without re-pasting state. End-to-end integration test.

## Phase 2 — Memory & recall (deliberate memory)
*Goal: the model can search and write memory; the pack carries relevant recalled facts; summaries
keep it bounded.*

- **2.1 Embed stage + memory writes.** Batch embeddings into `memory.embedding`; partial HNSW.
  → `docs/component-specs/worker.md`. *Accept:* new memories embedded; unembedded rows cost no index;
  re-embed via `rebuild --stages embed` works.
- **2.2 Hybrid recall (`recall.py`) + `POST /v1/recall`.** vector+lexical fusion, provenance.
  *Accept:* fusion ranks a known fact above a distractor; results filtered to project+tenant
  `[INV-11]`.
- **2.3 Pack recall slot (P3).** Reserve budget; dedupe against P1; pinned bypass. → `specs/context-pack.md`
  §4. *Accept:* recall never crowds out P0; determinism holds with recall present `[INV-8]`.
- **2.4 Tool server (`ariadne_tools`).** `memory_recall`/`memory_remember`/`state_*`/`checkpoint`/
  `restore`/`artifact_*`; resolve via `X-OpenWebUI-Chat-Id`; mint identity; proxy to `@chat:`.
  → `docs/component-specs/tools.md`. *Accept:* no op accepts a project id; no chat id ⇒ 428; chat A
  can't read chat B's memory `[INV-3]`.
- **2.5 Summarizer stage (T2).** segment→session→project roll-ups; digest slot (P2). *Accept:*
  segment boundary or every N turns produces a summary; digest fits its cap.

**Phase-2 exit:** in a long project, the model calls `memory_recall` and cites a fact established
many turns earlier that isn't in the current pack.

## Phase 3 — Durability & lifecycle
*Goal: nothing is lost; projects can be rebuilt, merged, exported, purged.*

- **3.1 Reconciler.** Backfill turns `outlet` missed via the OWUI chat REST API; per-chat HWM.
  → `docs/component-specs/reconciler.md`, ADR-0008. *Accept:* a direct-API turn (no `outlet`) lands in
  T0 within one interval; double-delivery ⇒ one event `[INV-5]`.
- **3.2 Jobs: rebuild.** Deterministic replay of T0 → T1/T2/T3. *Accept:* truncate projections,
  rebuild, brief is byte-identical for fixed extractor/embedding versions `[INV-2]`.
- **3.3 Jobs: merge / export / purge.** *Accept:* merge replays source events into target;
  export zip round-trips; purge leaves zero rows in every tier + empty blob prefix, irreversibly
  `[INV-14]`.
- **3.4 Checkpoints + restore (non-destructive).** *Accept:* restore appends a new version equal
  to the snapshot; history never rewound.
- **3.5 Reliability hardening.** DLQ + `XAUTOCLAIM` reclaim; `XADD`-fail inline persist; ingest
  lag metric. → `specs/queue-messages.md`. *Accept:* a poisoned message DLQs without blocking the
  stream; Redis-down turn still persists (degraded, not dropped).

## Phase 4 — Salience, safety & polish
*Goal: memory stays relevant over time; abuse is contained; multi-project UX is smooth.*

- **4.1 Salience / decay / forgetting.** score, decay, `/forget`. *Accept:* forgotten memory
  leaves recall; superseded facts hidden unless asked.
- **4.2 Contradiction / supersession.** apply `supersedes_hint`; tombstone old memories. *Accept:*
  a reversal (finding → false_positive) supersedes, doesn't duplicate.
- **4.3 Abuse cases.** implement + test `security/abuse-cases.md` (Tier 5): transcript trying to
  rewrite `constraints`; forged chat id; secret reaching embeddings; cross-tenant recall.
  *Accept:* each attack is blocked and has a regression test `[INV-3, INV-10, INV-11]`.
- **4.4 Multi-project UX.** folder auto-bind; `default_project`; per-project policy flags.
  *Accept:* a chat created in a bound folder resolves to that project at `inlet` `[uses folder_id]`.

---

## Task hygiene
- One task = one focused change with its tests. If a task needs more than a couple of files
  changed across services, split it.
- Every task PR states which component spec + invariant Checks it ran.
- A task is not done until `make validate-kb`, `make test`, `make lint` are green and the
  component-spec DoD bullets are satisfied.
