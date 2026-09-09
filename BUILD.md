# build.md — building Ariadne from the knowledge base

A step-by-step guide for a developer driving the build with a coding agent. This is the
**human's** bootstrap guide; `CLAUDE.md` is the **agent's** standing instructions. You mostly get
the repo in place, then drive one `BACKLOG.md` task at a time and let the gates verify each step.

## Mental model (read once)
- **The KB is loaded, not pasted.** Agentic tools read `CLAUDE.md` from the repo root every
  session; it pulls in the specific spec each task needs. You don't paste the architecture into a
  prompt.
- **You go task-by-task, in `BACKLOG.md` order.** Tasks are dependency-ordered and agent-sized.
  Each has acceptance criteria a test can prove; that's what "done" means.
- **The contracts are law.** `openapi/`, `schemas/`, `specs/`, `db/migrations/` and the invariants
  in `docs/INVARIANTS.md` are not suggestions. When code and a contract disagree, the contract
  wins (or you change both together, via an ADR).
- **Three caveats carry in from the KB** (§10) — real Open WebUI fixtures, migrations on a real
  Postgres, and the eval live hooks all need a running system to become ground truth.

---

## Step 1 — Prerequisites

- The `ariadne-kb.zip`, `git`, and **Docker + Docker Compose**.
- A coding agent. **Claude Code** is the natural fit (reads `CLAUDE.md` natively). Cursor /
  Windsurf / others work — see Step 3.
- **Model endpoints** the worker will call: an **embedding** model, and an **extractor** model
  (a small instruct model with JSON-mode / grammar-constrained decoding). Note their URLs/keys.
- An **Open WebUI** instance (0.11.x) — needed from Phase 1.7 onward for the filter/tool
  integration, not for early phases.
- Python + the KB validators, so you can run the checks before the `Makefile` exists:
  `pip install jsonschema openapi-spec-validator pglast jsonpatch pyyaml`.

## Step 2 — Put the repo in place

```bash
unzip ariadne-kb.zip
cd ariadne-kb
git init && git add -A && git commit -m "import knowledge base"
```

It's a knowledge base, not yet a codebase — Phase 0 turns it into one. Confirm the KB checks pass
on a clean import (this is the interim gate until `make validate-kb` exists in Step 5):

```bash
python -c "from openapi_spec_validator import validate; from openapi_spec_validator.readers import read_from_filename as r; import copy; s,_=r('openapi/ariadne-tools.yaml'); validate(s); print('tools OK')"
python -c "import glob,pglast; [pglast.parse_sql(open(f).read()) for f in glob.glob('db/migrations/*.sql')]; print('migrations parse OK')"
python eval/run.py all
```

## Step 3 — Point your agent at the repo

- **Claude Code:** `claude` in the repo root. It auto-loads `CLAUDE.md`. Have it read the map
  first: *"Read `CLAUDE.md` and `docs/INDEX.md`, then summarise the build loop you'll follow.
  Don't write code yet."*
- **Cursor / Windsurf / other rules-file agents:** symlink or copy `CLAUDE.md` to the file they
  read (`.cursorrules`, their rules panel, etc.). `AGENTS.md` is already present as a cross-tool
  pointer.
- **Chat/desktop app:** upload the zip or the task's files. Good for design review and single-file
  work; use a repo agent for the build loop.

## Step 4 — The build loop (the pattern you repeat for every task)

1. Pick the next task in `BACKLOG.md` (respect the phase order and any `needs`).
2. Give the agent a **structural** prompt — point at the spec, name the gate, scope it tight:

   > Work BACKLOG task **<N>** only. Read its component spec in `docs/component-specs/` and the
   > contracts it names. Implement it, satisfy the task's acceptance criteria and the spec's
   > Definition of Done, and run the invariant Checks it cites. Then run `make validate-kb test
   > lint`. Do not touch anything outside this task's scope. If a contract looks wrong, stop and
   > tell me rather than diverging.

3. Verify the gate went green (Step 9). Review the diff.
4. `git commit`. Move to the next task. **Don't let the agent run phases ahead** — the phase-exit
   integration tests are your checkpoints.

Keep prompts short: the rules already live in `CLAUDE.md` and the specs. Re-explaining them in the
prompt only invites drift from the files.

## Step 5 — Phase 0: turn the KB into a running skeleton

> **Reality check:** the `Makefile`, `docker-compose.yml`, and per-service `Dockerfile`s are
> *referenced* throughout the KB but were not written — creating them is literally task 0.1–0.2.
> Until they exist, use the raw validator commands from Step 2 as your gate.

Do these in order; each is one agent session.

- **0.1 — scaffold + make targets.**
  > Do BACKLOG **0.1** only: create the `packages/*`, `integrations/`, `tests/`, `eval/`,
  > `deploy/compose/` layout from `CLAUDE.md`; a `pyproject.toml` workspace; and a `Makefile` with
  > the targets `CLAUDE.md` names — `validate-kb`, `test`, `lint`, `up`, `migrate`. Wire
  > `make validate-kb` to actually run the OpenAPI + JSON-Schema + SQL-parse + markdown-reference
  > checks and `python eval/run.py all`. Stop when 0.1's acceptance criteria pass.
- **0.2 — compose stack (docker-as-a-service).**
  > Do BACKLOG **0.2**: write `deploy/compose/docker-compose.yml` and the per-service Dockerfiles
  > for Postgres 17 + pgvector, Redis, MinIO, and the `api`/`worker`/`tools`/`reconciler`
  > containers, with health checks, `depends_on`, and restart policies. `make up` must come up
  > healthy. Validate the compose file with `docker compose config`.
- **0.3 — migrations on a real Postgres.** Closes the KB's "parser-verified only" caveat.
  > Do BACKLOG **0.3**: create the `ariadne_migrate`/`ariadne_app` roles per `db/README.md`, apply
  > `db/migrations/0001–0006` with `dbmate`, and prove `ariadne_app` cannot bypass RLS
  > (tenant-B row invisible under `ariadne.tenant=A`) — INV-11.
- **0.4 — `ariadne_common`.** config, db pool + tenant GUC, redis, auth mint/verify, schema
  loaders. Gate: the `docs/component-specs/common.md` Definition of Done (INV-11, INV-12, INV-4).
- **0.5 — health + CI.** `/healthz`, `/readyz`; CI runs `make validate-kb test lint` and blocks a
  merge that reddens `validate-kb`.

**Phase 0 exit:** `make up` healthy, `make migrate` applies on a fresh DB, `curl /readyz` →
`ready:true`, CI green.

## Step 6 — Phase 1: the minimal continuity loop (the core value)

Work 1.1 → 1.8 in order (auth/tenancy → projects+sessions → scope resolution → ingest+persist →
extractor+state → pack builder → the filter → slash commands). Two notes:

- **Before 1.7 (the filter), capture real Open WebUI payloads.** The shipped `fixtures/openwebui/`
  are documented reference shapes, not live captures. Follow `fixtures/openwebui/README.md` to
  record real ones from your instance and replace them; the `VERIFY:` fields (where `folder_id`
  sits; which headers reach the tool server) must be settled against reality before you trust the
  resolver. Don't let the agent mark integration "done" against the reference shapes alone.
- The pack builder (1.6) has a **byte-exact golden** (`eval/pack/`) — `python eval/run.py pack`
  must stay green; a rendering change updates the golden in the same commit.

**Phase 1 exit:** open a fresh chat, `/resume <slug>`, and the model answers "where did we leave
off" from the injected pack without you re-pasting state. That end-to-end test is the milestone.

## Step 7 — Phase 2: memory & recall

Work 2.1 → 2.5 (embed stage → hybrid recall → pack recall slot → tool server → summarizer).

- **At 2.4 (the tool server), verify header forwarding on your instance.** Set
  `ENABLE_FORWARD_USER_INFO_HEADERS=true` (or the per-connection `{{CHAT_ID}}` header) and confirm
  a tool call arrives with `X-OpenWebUI-Chat-Id` — this is the whole basis of INV-3. A tool call
  with no chat id must fail closed with 428, never a fallback project.
- Keep `python eval/run.py extraction --live <api>` and the recall tests honest; the gate is
  patch-validity ≥ 0.98, rubric ≥ 0.90 (`docs/test-strategy.md`).

**Phase 2 exit:** in a long project, the model calls `memory_recall` and cites a fact from many
turns earlier that isn't in the current pack.

## Step 8 — Phase 3: durability & lifecycle

Work 3.1 → 3.5 (reconciler → rebuild → merge/export/purge → checkpoints → reliability hardening).
The reconciler (3.1) is mandatory, not optional — it's what catches direct-API turns `outlet`
misses (ADR-0008). Prove rebuild is byte-identical from T0 (INV-2) and purge leaves nothing
(INV-14).

## Step 9 — Phase 4: salience, safety & polish

Work 4.1 → 4.4. **4.3 turns `security/abuse-cases.md` into regression tests** — each AC-n becomes a
test that must pass (transcript injection, forged chat id, secret-in-transcript, cross-tenant
recall). Don't skip this; it's where the safety invariants get their teeth.

## Step 10 — The gates (what "done" means, every time)

A task is done only when all of these are green:
1. `make validate-kb` — KB contracts + reference checks + `eval/run.py`.
2. `make test` (and `make test-int` for anything touching DB/queue/filter).
3. `make lint` — `ruff` + `mypy --strict`.
4. The **Definition of Done** bullets in the task's `docs/component-specs/<x>.md`.
5. The **invariant Checks** in `docs/INVARIANTS.md` for anything the task touched.
6. At a phase boundary, the phase-exit integration test.

## Step 11 — Guardrails (what to reject in review)

The KB's value evaporates if contracts are treated as optional. Push back when an agent:
- skips schema validation "for now", or trusts extractor output unvalidated (breaks ADR-0010 /
  INV-4);
- adds a project/tenant/user id to the tool surface (breaks INV-3 — the safety boundary);
- edits a spec/schema to match its code instead of the reverse (drift — the thing the KB exists to
  prevent);
- runs several phases ahead, or marks the filter/tool integration done against the **reference**
  fixtures rather than captured ones;
- changes a decision silently. A real design change updates the ADR **and** the OpenAPI/schema in
  the same commit; a shortcut gets rejected.

## Step 12 — Caveats to close during the build

Carried in from the KB, each with where it lands:
- **Capture real Open WebUI fixtures** (Phase 1.7) — replace the reference shapes; settle the
  `VERIFY:` fields. `fixtures/openwebui/README.md`.
- **Run migrations on a real PG17 + pgvector** (Phase 0.3) — the KB only parser-verified them.
- **Wire the eval live hooks** (Phases 1.6/1.5/2.x) — `eval/run.py`'s `TODO(live)` paths need the
  built system; offline validation already passes.
- **Re-verify Open WebUI version-gated behaviour** on any Open WebUI upgrade —
  `docs/open-webui-integration.md` §6 (the `request`/`outlet` semantics, header forwarding, and
  Native-vs-Legacy default can shift between releases).

---

### One-screen quickstart
```bash
unzip ariadne-kb.zip && cd ariadne-kb && git init && git add -A && git commit -m "kb"
python eval/run.py all                      # sanity: fixtures valid
claude                                        # or your agent; it reads CLAUDE.md
#  → "Read CLAUDE.md and docs/INDEX.md; do BACKLOG task 0.1 only; stop when its gates pass."
#  → then 0.2, 0.3 … one task per session, committing between, until Phase 1 exit.
```
Follow `BACKLOG.md` from there. When in doubt, the reading order is `docs/INDEX.md`.
