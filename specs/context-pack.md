# Context-pack specification

**Owner component:** `ariadne-api` (pack builder) — hot path, p99 < 300 ms
**Produced by:** `POST /v1/context-pack` → `ContextPackResponse.text`
**Consumed by:** the Open WebUI filter `inlet`, injected into the chat request

The pack is the one thing the model actually sees. This spec makes its construction
**deterministic**: the same inputs (state version, budget, tokenizer, recall results) must
produce byte-identical `text`, so packs are cacheable and testable with golden vectors.

---

## 1. Anatomy

The pack is Markdown wrapped in stable sentinels so the filter (and a human) can find,
strip, or replace it:

```
<!-- ariadne:begin v=1 project=recon-acme sv=142 pack=6f1c... -->
# Project brief — Acme external assessment
_Resuming project `recon-acme`. This context is maintained by Ariadne; treat it as ground truth._

## Objective
Map the external attack surface of acme.com and validate exploitable findings.

## Constraints
- Scope: *.acme.com and 203.0.113.0/24 only. No social engineering.
- Engagement window ends 2026-09-20.

## Pinned
- Client contact prefers findings in CVSS 3.1.

## Environment
Targets: acme.com, api.acme.com, 203.0.113.0/24
Tooling: nmap, ffuf, burp, custom py
Creds: artifact://creds.kdbx

## Open threads
- [t4] (in_progress) SSRF candidate in image-proxy — needs OOB confirmation

## To do
- [ ] [todo9] Re-test rate-limit bypass after WAF change

## Findings
- [f2] **high** (confirmed) IDOR in /v2/orders → artifact://f2-poc.md

## Decisions
- [d17] Treat the /v2 API as primary attack surface

## Relevant memory
- (finding) IDOR confirmed in /v2/orders; cross-tenant read by decrementing order_id.

<!-- ariadne:end pack=6f1c... -->
```

The sentinels carry the schema version (`v`), project slug, state version (`sv`) and the
`pack_id`. The filter removes any previous `ariadne:begin..end` block before injecting a new
one, so re-injection is idempotent and never stacks.

### Section order (fixed)
`header · objective · constraints · pins · environment · open_threads · todos · findings ·
decisions · entities · glossary · digest · recall · footer`

Order is fixed regardless of budget; budgeting drops or truncates sections, never reorders
them. `command_ack` (if a slash command ran) renders immediately after `header`; `staleness`
(if `stale_turns > 0`) renders immediately before `footer`.

---

## 2. Budget algorithm (priority knapsack)

Input: `budget_tokens` (default 4000), the state document, recall results, tokenizer.
Sections are assigned priority classes; we fill in priority order, and **within the P1 pool**
allocate by a largest-share rule so no single list starves the others.

| Priority | Sections | Rule |
|---|---|---|
| **P0 — must** | header, objective, constraints, pins, footer, command_ack, staleness | Always included in full. If P0 alone exceeds budget, include them anyway and set `truncated=true` (never drop a constraint or pin). |
| **P1 — core state** | open_threads, todos, findings, decisions, environment | Share the pool left after P0. Each section gets `max(min_floor, proportional share)`. Items within a section are ordered by the section's sort key (below) and truncated with a `+N more` line. |
| **P2 — digest** | digest (latest project/session summary) | Filled only if P1 fully fit. One paragraph, hard cap `DIGEST_MAX_TOKENS` (default 400). |
| **P3 — recall** | recall | Query-dependent memories. Reserve `recall_reserve = min(1200, 30% of budget)` up front so recall is not crowded out; unused reserve returns to P2/P1. |
| **P4 — reference** | entities, glossary | Only if everything above fit. Truncatable. |

### Section sort keys (determinism)
- **open_threads:** status rank `in_progress < blocked < open < resolved`, then ascending `id`.
  Resolved threads are omitted unless they fit after all P1.
- **todos:** `done=false` before `done=true`; incomplete by ascending `id`; completed omitted
  unless space remains.
- **findings:** severity desc (`critical>high>medium>low>info`), then state rank
  `confirmed < suspected < remediated < accepted < false_positive`, then `id`.
- **decisions:** most recent `at_seq` first (falls back to descending `id`); superseded last.
- **entities:** referenced-in-recall first, then ascending `id`.
- **recall:** fused score desc (see §4), ties broken by `source_seq` desc (newer first).

`min_floor` per P1 section defaults: threads 2 items, todos 3, findings 3, decisions 2,
environment 1 line each of targets/tooling. Floors are skipped for empty sections.

### Truncation marker
When a section is cut, append exactly: `- …(+N more; ask or use memory_recall)` so the model
knows more exists and how to get it. `N` is the count omitted.

---

## 3. Tokenizer selection

Budget accounting must match the **target chat model**, chosen from `ContextPackRequest.model`:

1. Model maps to a known OpenAI-family tokenizer → `o200k_base` (gpt-4o/o-series) or
   `cl100k_base` (older). 
2. Model maps to a HF tokenizer id → `hf:<id>`, loaded from a bundled table.
3. Unknown → `heuristic`: `ceil(chars/4)` with a +10% safety margin.

The chosen tokenizer name is returned in `ContextPackResponse.tokenizer` and is part of the
cache key, because token counts (hence what fits) differ across tokenizers. Golden tests pin
one tokenizer so expected byte output is stable.

---

## 4. Recall integration

The pack builder calls the same retrieval path as `POST /v1/recall` with the user `query`,
`k = request.recall.k` (default 8), filtered to the project. Fusion:

```
fused = w_vec * rr(vec_rank) + w_lex * rr(lex_rank) + w_sal * salience
rr(r) = 1 / (60 + r)          # reciprocal-rank, k0=60
defaults: w_vec=1.0, w_lex=0.8, w_sal=0.2
```

Pinned memories bypass fusion and are rendered under **Pinned** (P0) — not here — so they are
never at risk from the budget. Recall omits memories whose `source_seq` is already represented
verbatim in a P1 section, to avoid duplication (dedupe by normalized text hash).

---

## 5. Caching

Two layers:

- **Rendered-section cache** keyed `ariadne:pack:{project_id}:{state_version}:{tokenizer}` →
  the fully rendered P0+P1+P2+P4 block (everything **except** recall, which is query-dependent).
  Invalidated whenever `state_version` changes (state PATCH, restore, rebuild).
- **Whole-pack cache** keyed
  `ariadne:pack:{project_id}:{state_version}:{budget}:{tokenizer}:{query_hash}:{k}` with a short
  TTL (`PACK_CACHE_TTL`, default 90 s) for repeat inlets on the same turn (retries, regen).

`query_hash = sha256(normalized query)`. `cache` in the response reports `hit|miss|bypass`
(`bypass` when a slash command forced fresh assembly).

Determinism requirement: given identical `(state_version, budget, tokenizer, ordered recall
ids)` the rendered `text` is byte-identical. No timestamps, no map iteration order, no random
tie-breaks — all ties broken by the explicit keys above.

---

## 6. Slash commands

If `query` begins with a recognised command (after trimming leading whitespace), the builder
executes it, sets `ContextPackResponse.command`, and:

- **strip = true** for commands that are pure control and should not reach the model as a user
  turn: `/resume`, `/project *`, `/pin`, `/unpin`, `/checkpoint`, `/restore`, `/forget`,
  `/state`. The filter deletes the command line from the outgoing user message.
- **strip = false** when the command's residue is meaningful to the model (none in v1; reserved).

`command.ack` is one line rendered in the `command_ack` slot, e.g.
`Resumed project **recon-acme** (v142). 6 findings, 1 open thread.` A failed command
(`ok=false`) still returns 200 with an explanatory `ack`; the pack is still built for the
resolved (or current) project.

Recognised grammar:

```
/resume <slug>
/project new <slug> [title...]
/project rename <slug>
/project list
/pin <text...>
/unpin <n>
/forget <memory_id | text...>
/checkpoint <label> [note...]
/restore <label>
/state
```

---

## 7. Injection modes (filter side)

`user_valves.inject_mode`:

- **system** (default): the pack is merged into the request's system message. Per Open WebUI
  behaviour there must be exactly **one** system message; the filter prepends the pack to any
  existing system content, separated by a blank line, rather than adding a second system turn.
- **user_prefix**: the pack is prepended to the latest user message, inside the sentinels.
  Used for models/endpoints that ignore or flatten system messages.

Either way the previous pack block (matched by sentinels) is removed first. The filter never
injects when `text` is empty (fresh project, nothing to say yet).

---

## 8. Staleness

`stale_turns` = ingested turns whose `event.seq` exceeds `state_doc.meta.updated_seq`. When
> 0 the `staleness` slot renders:
`_Note: {n} recent turn(s) not yet folded into this brief._` so the model knows the brief may
trail the very latest exchange. It never blocks; extraction catches up asynchronously.

---

## 9. Golden test vector

`eval/pack/recon-acme.json` holds `{state_doc, recall_items, budget, tokenizer}` and
`eval/pack/recon-acme.expected.md` the exact bytes. The contract test asserts equality and
that `tokens ≤ budget` (or `truncated=true`). Any change to rendering updates the golden file
in the same commit, which is the human review signal that output changed.
