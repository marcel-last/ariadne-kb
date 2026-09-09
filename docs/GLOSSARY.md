# Glossary

One definition per term, so code, tests, specs and prompts use the same nouns. When a term
here maps to a concrete artifact (a table, a schema, an endpoint), that's named. Read this
before `INVARIANTS.md` and the ADRs.

## Scopes (nesting, outermost first)

- **Tenant** — one Open WebUI instance. Derived from the `X-Ariadne-Key` service key, never
  from request input. Table: `tenant`. The unit of hard isolation (see INV-11).
- **User** — an Open WebUI account within a tenant. Derived from the `sub` claim of the
  `X-Ariadne-Identity` JWT. Table: `app_user` (`owui_user_id`).
- **Project** — the unit of continuity. Owns its state, summaries, memory and artifacts;
  has a `slug`, an ACL, and a lifecycle (`active` → `archived` → `purging`). Many chats can
  map to one project. Table: `project`.
- **Session** — exactly one Open WebUI chat, bound to exactly one project. Keyed by
  `chat_id`. Table: `session`. See **binding**.
- **Turn** — one user message plus the assistant reply it produced; the atomic unit of
  ingestion. Not a database table — a turn becomes one or more **events**.

## Memory tiers

- **T0 — event log** — the append-only, gap-free record of everything that happened, per
  project. **The single source of truth** (INV-2). Table: `event`. Everything below is a
  projection rebuildable from it.
- **T1 — the brief** (a.k.a. *working-state document*, *state doc*) — the compact structured
  summary of the project's live state: objective, constraints, decisions, open threads, todos,
  findings, entities, glossary, pins. Versioned. Schema: `schemas/state-doc.schema.json`
  (`ariadne.state/1`). Tables: `state_doc`, `state_doc_history`.
- **T2 — summaries** — hierarchical natural-language roll-ups (segment → session → project).
  Table: `summary`.
- **T3 — semantic memory** — typed, individually-retrievable memories (fact, decision, entity,
  procedure, todo, finding, chunk, summary) with embeddings and full-text vectors for hybrid
  search. Table: `memory`.
- **T4 — artifacts** — larger content-addressed blobs (code, reports, PoCs) stored by name in
  an object store, referenced from the brief/memory as `artifact://<name>`. Table: `artifact`.

## The moving parts

- **Context pack** (a.k.a. *pack*) — the budgeted markdown block Ariadne assembles per turn and
  the filter injects into the model request. Bounded (~4k tokens by default), deterministic.
  Spec: `specs/context-pack.md`. Endpoint: `POST /v1/context-pack`.
- **Pack builder** — the component inside `ariadne-api` that renders the pack (priority knapsack,
  tokenizer, caching). Hot path (p99 < 300 ms).
- **Filter** — the Open WebUI Filter function that injects the pack (`inlet`) and ships the
  completed turn (`outlet`). Runs inside Open WebUI's process. Required touchpoint. See
  `docs/open-webui-integration.md`.
- **Tool server** — `ariadne-tools`, an OpenAPI tool server registered in Open WebUI, exposing
  memory operations the **model** can call. Recommended touchpoint. Spec: `openapi/ariadne-tools.yaml`.
- **Reconciler** — a background component that reads the Open WebUI chat REST API and backfills
  turns the `outlet` path missed (e.g. direct-API turns). Mandatory, per ADR-0008.
- **Worker** — `ariadne-worker`, the Redis-Streams consumer that runs the ingestion **stages**.
- **Extractor** — the LLM step (worker stage) that reads a turn + the current brief and emits a
  constrained JSON-Patch plus memories. Prompt: `prompts/extractor.md`. Output schema:
  `schemas/extractor-output.schema.json`.
- **Summarizer** — the worker stage that produces T2 summaries at segment/session/project level.

## Ingestion vocabulary

- **Stage** — one step of the worker pipeline: `persist → embed → extract → summarize`.
  Independent and idempotent; progress tracked per project in `stage_cursor`.
- **seq** — a per-project, gap-free, monotonic sequence number assigned to each event at the
  persist stage. Provenance for everything downstream (`source_seq`). Assigned by
  `ariadne_next_seq()`; uniqueness backstopped by `UNIQUE (project_id, seq)`. See INV-6.
- **content_hash** — `sha256` of a message's canonical form; the idempotency key. Constraint:
  `UNIQUE (project_id, content_hash)` on `event`. See INV-5.
- **Segment** — a contiguous run of turns on one topic/phase; the summarizer's base unit.
  A **segment boundary** is the extractor's hint that a new segment has begun.

## State-document vocabulary

- **Objective** — the one-line statement of what the project is for. Always in the pack.
- **Constraint** — a scope rule, deadline or hard limit. Changes here are review-flagged
  (see `security/abuse-cases.md`, Tier 5).
- **Open thread** — a live line of inquiry (`open` / `in_progress` / `blocked` / `resolved`).
  Capped at 12; overflow demotes to T3, never dropped.
- **Finding** — a domain result with a `state` (`suspected` / `confirmed` / `false_positive` /
  `remediated` / `accepted`) and optional `severity`. The `default` template maps these to
  security findings.
- **Decision** — a recorded choice, optionally superseded by a later one.
- **Entity** — a named thing in the working environment (host, service, credential-ref, …) with
  a stable local id.
- **Pin** — a user/tool-authored fact that is **always** kept in the pack and **never** touched
  by the extractor (INV-4). Path `/pins`.
- **local id** — a short stable id unique within its array (`d17`, `t4`, `todo9`, `f2`, `e2`),
  minted by the extractor and reused on update. `$defs/localId`.
- **Checkpoint** — a labelled snapshot of a brief version, restorable non-destructively.

## Cross-cutting

- **Binding** — the mapping from a chat (`chat_id`) to a project, decided by the resolution
  ladder (existing → slash command → folder map → default → implicit). `bound_by` records which.
  The model never influences it directly (INV-3).
- **Fail open** — on any Ariadne error or timeout, the filter returns the chat request unchanged
  so the conversation proceeds without augmentation (INV-1).
- **Salience / decay** — a memory's current importance score, used for ranking and forgetting.
- **Supersession** — marking a memory `valid=false` and pointing `superseded_by` at its
  replacement, instead of deleting it (history is kept).
- **Optimistic concurrency** — state edits carry a `base_version`; a mismatch returns `409`
  (`version_conflict`) rather than silently clobbering (INV-7).
- **RLS** — Postgres row-level security keyed on the `ariadne.tenant` GUC, the enforcement
  mechanism behind tenant isolation (INV-11). Migration: `db/migrations/0006_rls.sql`.
- **Valve / UserValve** — Open WebUI's admin-level / per-user filter settings; Ariadne uses a
  `UserValves` block for `default_project`, `auto_bind_folders`, `inject_mode`.
- **Native / Legacy function calling** — Open WebUI's two tool-calling modes. Ariadne requires
  **Native** (ADR-0007); Legacy is unsupported by Open WebUI and disables the tool surface.
