# Invariants

These are the properties that must hold for Ariadne to be correct and safe. They are the
rules an agent must not violate and a reviewer must not let regress. Each is written as a
**testable property**, with the **mechanism** that enforces it and a **check** that proves it.
If a change would break one of these, the change is wrong — or the invariant needs an explicit
ADR to change it first.

Format: **INV-n — statement** · *why* · **Enforced by** · **Check** · *(ADR)*.

Priority tiers: **[SAFETY]** breaking it harms the user or leaks data; **[CORRECTNESS]** breaking
it corrupts state; **[QUALITY]** breaking it degrades output. Fix SAFETY before shipping anything.

---

### INV-1 — Ariadne never breaks a chat. **[SAFETY]**
A conversation must proceed normally whether Ariadne is fast, slow, wrong, or down.
- **Why:** Ariadne augments Open WebUI; it is never in the critical path of a user getting a reply.
- **Enforced by:** the filter wraps every Ariadne call in a ≤ 400 ms timeout and a try/except and
  returns `body` unchanged on any error; injection happens in `inlet` (which Open WebUI treats
  gently) and turn-shipping in `outlet` is fire-and-forget (`202`, never awaited for success).
- **Check:** fault-injection tests — Ariadne stopped, Ariadne sleeping past the timeout, Ariadne
  returning 500 / malformed JSON — each asserts the chat still completes and no exception escapes
  the filter. `POST /v1/context-pack` returning `503` must leave the turn unaugmented, not failed.
- *(ADR-0004)*

### INV-2 — T0 is the only source of truth; T1/T2/T3 are rebuildable projections. **[CORRECTNESS]**
The event log (`event`) is authoritative; the brief, summaries and memory index can always be
regenerated from it.
- **Why:** makes the system recoverable, auditable, and safe to re-index after model/prompt changes.
- **Enforced by:** only the persist stage writes `event`, append-only; `rebuild` replays events to
  regenerate T1/T2/T3; `db/README.md` lists exactly which tables are safe to drop and rebuild.
- **Check:** rebuild determinism test — snapshot state, `TRUNCATE` the projection tables, run
  `POST /v1/projects/{id}/rebuild`, assert the regenerated brief is byte-identical for the same
  extractor/embedding versions. No projection table is ever the sole home of any fact.
- *(ADR-0006)*

### INV-3 — The model never supplies a project id. **[SAFETY]**
Nothing the model emits can select which project's memory it reaches.
- **Why:** a model that could name a project could read or corrupt another project's memory; this
  is the core multi-tenant/cross-project safety boundary.
- **Enforced by:** `openapi/ariadne-tools.yaml` defines **no** `project_id` parameter on any operation; the
  tool server resolves the project from the forwarded `X-OpenWebUI-Chat-Id` via the binding; a
  missing/unbound chat id fails **closed** with `428`, never a fallback to "some" project.
- **Check:** (a) schema test — no tool operation has a property matching `project`; (b) behaviour
  test — a tool call with no chat-id header returns `428`; (c) a tool call for chat A can never
  return chat B's project memory.
- *(ADR-0005)*

### INV-4 — Pins, `meta` and `schema` are immutable to the extractor. **[CORRECTNESS]**
Automated extraction can never edit or remove a user's pinned facts or the document's
system-managed fields.
- **Why:** pins are the user's guaranteed-kept context; letting the extractor touch them destroys
  the one thing the user explicitly controls.
- **Enforced by:** `schemas/extractor-output.schema.json`'s path pattern only permits the mutable roots
  (`objective|constraints|environment|entities|decisions|open_threads|todos|findings|glossary`);
  the API re-checks author on `/state` PATCH so only `user`/`tool` authors touch `/pins`.
- **Check:** an extractor patch with a path under `/pins`, `/meta` or `/schema` is rejected by the
  schema; a `PATCH /state` with `author=extractor` touching `/pins` is refused by the API.
- *(ADR-0003)*

### INV-5 — Every turn write is idempotent on `(project_id, content_hash)`. **[CORRECTNESS]**
Re-delivering the same turn (outlet retry + reconciler backfill) must not duplicate it.
- **Why:** the `outlet` path and the reconciler intentionally overlap; at-least-once queue delivery
  re-runs stages. Without idempotency the log would double-count.
- **Enforced by:** `UNIQUE (project_id, content_hash)` on `event`, inserted with
  `ON CONFLICT DO NOTHING`; `content_hash = sha256(canonical{chat_id, role, owui_message_id|text})`.
- **Check:** ingest the same turn twice → exactly one `event` row; the second `POST /v1/turns`
  returns `deduplicated: true`. Property test over reordered/duplicated deliveries.
- *(ADR-0008)*

### INV-6 — Per-project `seq` is gap-free and strictly monotonic. **[CORRECTNESS]**
Each project's events are numbered 1,2,3,… with no gaps and no duplicates, in ingest order.
- **Why:** summaries, rebuild boundaries and provenance (`source_seq`) all rely on a dense,
  ordered sequence per project.
- **Enforced by:** `ariadne_next_seq()` increments `project.last_seq` under a
  `pg_advisory_xact_lock`; `UNIQUE (project_id, seq)` is the backstop; the persist stage is the
  only assigner and serializes per project (Redis lock, PG advisory fallback).
- **Check:** concurrent-ingest stress test on one project → sequence is exactly `1..N`, no gaps,
  no dupes; a forced double-assign hits the unique constraint, not a silent overwrite.
- *(ADR-0001, ADR-0006)*

### INV-7 — State edits are optimistic-concurrency-guarded. **[CORRECTNESS]**
Two writers cannot silently clobber each other's brief edits.
- **Why:** the extractor, a tool call and a user command can all try to edit the brief around the
  same turn.
- **Enforced by:** every `PATCH /state` carries `base_version`; a mismatch returns `409`
  (`version_conflict`) with the current version; the loser re-reads and retries.
- **Check:** two patches with the same `base_version` → the first succeeds, the second gets `409`;
  no version is ever skipped or overwritten.
- *(ADR-0003)*

### INV-8 — The context pack is deterministic. **[QUALITY]**
Given the same `(state_version, budget, tokenizer, ordered recall ids)`, the rendered pack text is
byte-identical.
- **Why:** determinism is what makes the pack cacheable and testable, and keeps behaviour stable
  across identical turns.
- **Enforced by:** fixed section order; all ties broken by explicit sort keys (no map-iteration
  order, no timestamps, no randomness) — see `specs/context-pack.md` §2, §5.
- **Check:** golden-vector test — `eval/pack/*.json` → exact expected `.md`; re-running yields the
  same bytes; changing rendering forces the golden file to change in the same commit.
- *(ADR-0002)*

### INV-9 — The pack respects its token budget. **[QUALITY]**
Pack tokens ≤ `budget_tokens`, except when the mandatory (P0) sections alone exceed it, in which
case they are still included and `truncated=true`.
- **Why:** a pack that blows the budget defeats the whole point (bounded, predictable cost).
- **Enforced by:** the priority-knapsack fill order in `specs/context-pack.md` §2; P0 =
  header/objective/constraints/pins/footer always kept.
- **Check:** property test across random briefs and budgets asserts `tokens ≤ budget ∨ truncated`;
  constraints and pins are never dropped even under a tiny budget.
- *(ADR-0002)*

### INV-10 — Secrets never enter the brief, memory, or embeddings. **[SAFETY]**
Credentials, keys and tokens are recorded only as references, never as values.
- **Why:** Ariadne persists and indexes conversation content; a leaked secret would be stored,
  embedded, and retrievable.
- **Enforced by:** the `creds_ref` regex guard in `schemas/state-doc.schema.json`
  (`(?i)(password|secret|api[_-]?key|token)\s*[:=]` rejected); the extractor prompt rule 8; the
  ingest redaction stage before embedding.
- **Check:** a turn containing a credential → no `event`/`memory`/`state` field contains the secret
  value, no embedding is computed over it; the schema rejects a `creds_ref` with an inline secret.
  (Expanded in `security/abuse-cases.md`, Tier 5.)
- *(ADR-0005)*

### INV-11 — Tenant isolation is absolute. **[SAFETY]**
No query, however buggy, returns or writes another tenant's rows.
- **Why:** defence in depth behind application authz; a forgotten `WHERE` must not leak data.
- **Enforced by:** RLS `FORCE`d on every tenant-scoped table, policy `tenant_id =
  ariadne_current_tenant()`; the app connects as non-superuser `ariadne_app`; the API sets
  `SET LOCAL ariadne.tenant` from the verified claim, never from request input.
- **Check:** with `ariadne.tenant = A`, a `SELECT *` over each tenant-scoped table returns zero
  rows belonging to tenant B; running the app role confirms it cannot bypass RLS; forgetting to
  set the GUC yields zero rows (fail-closed), not all rows.
- *(ADR-0001)*

### INV-12 — Identity claims are short-lived and server-verified. **[SAFETY]**
The user identity is proven per request, not asserted.
- **Why:** the tenant/user drive every authz and RLS decision; a forgeable or long-lived identity
  undermines all of it.
- **Enforced by:** `X-Ariadne-Identity` is an HS256 JWT with ≤ 300 s lifetime verified against the
  shared secret; tenant comes from `X-Ariadne-Key`; body-supplied ids are ignored when a header/
  binding can supply them.
- **Check:** an expired, unsigned, or wrong-secret claim is rejected (`401`); a request that tries
  to set its own tenant/user in the body cannot override the header-derived values.
- *(ADR-0005)*

### INV-13 — Extraction failure never blocks ingestion. **[CORRECTNESS]**
If the extractor errors or emits invalid output, T0 and T3 still persist; only T1 is deferred.
- **Why:** the extractor is the highest-variance component; it must not be able to stall the log or
  lose turns.
- **Enforced by:** stage independence (`persist`/`embed` run regardless of `extract`); the worker
  keeps `memories` even if the state patch is rejected, retries once, then skips T1 for that turn;
  the next successful turn or a `rebuild` reconciles the brief. See `prompts/extractor.md` §failure.
- **Check:** feed the extractor invalid/rejected output → the `event` and any `memory` rows still
  exist, the brief is unchanged (not corrupted), and `stale_turns` reflects the deferral.
- *(ADR-0003)*

### INV-14 — Purge is complete and irreversible. **[SAFETY]**
Deleting a project with `purge=true` destroys every tier plus its object-store prefix and cache.
- **Why:** the erasure/right-to-be-forgotten path must leave nothing behind.
- **Enforced by:** `DELETE /v1/projects/{id}?purge=true` enqueues a `purge` job that removes
  events, state history, summaries, memories, artifacts (and their blobs) and cache keys, then the
  `project` row; FKs `ON DELETE CASCADE` back this up.
- **Check:** after a purge completes, every tenant-scoped table has zero rows for that project id
  and the object-store prefix is empty; the operation cannot be undone.
- *(ADR-0006)*

---

## How to use this file

- **Building a component?** Find the invariants that name it (grep the *Enforced by* lines) and
  make them true, then add the *Check* to that component's tests before calling it done.
- **Reviewing a change?** If it touches ingestion, state, the pack, auth, or the tool surface,
  re-run the relevant *Checks*. A green diff that reddens a Check is a regression, not a feature.
- **Want to change an invariant?** Write or amend an ADR first (status `Proposed` → `Accepted`),
  because every invariant here is downstream of a decision recorded in `docs/adr/`.
