# Index

A one-page map of the knowledge base: what each file is for and when to read it. The root
`README.md` lists the files tier by tier; this is the *reading order* by what you're trying to do.

## Start here (everyone, once)
1. `GLOSSARY.md` — the vocabulary. Every other file uses these nouns.
2. `architecture.md` — the *why* and *what*: goals, scopes, the T0–T4 memory tiers, the Open
   WebUI integration, and the condensed decision list. Everything else is a contract that pins
   down one part of this.
3. `INVARIANTS.md` — the 14 properties nothing may break.

## If you are implementing a component
1. `../CLAUDE.md` — the working rules, repo layout, conventions, and definition of done (read
   every session).
2. `component-specs/<your component>.md` — responsibilities, interfaces, failure behaviour, DoD.
3. The contracts your component touches:
   - HTTP surface → `../openapi/ariadne-api.yaml`, `../openapi/ariadne-tools.yaml`
   - the brief → `../schemas/state-doc.schema.json`
   - extraction → `../schemas/extractor-output.schema.json`, `../prompts/extractor.md`
   - the pack → `../specs/context-pack.md`
   - the queue → `../specs/queue-messages.md`
   - the database → `../db/migrations/`, `../db/README.md`
   - Open WebUI → `open-webui-integration.md` (+ `../fixtures/openwebui/`)
4. `adr/` — the reasoning behind any behaviour you're tempted to change.
5. `../BACKLOG.md` — the next task, with acceptance criteria.

## If you are testing
- `test-strategy.md` — the layers, the eval loop, and the invariant→test map.
- `../eval/` — the harness (`run.py`) and golden datasets (pack, extraction, resume).
- `../security/abuse-cases.md` — the adversarial cases to keep passing.

## If you are operating it
- `config-reference.md` — every knob and its default.
- `runbook.md` — bring-up, day-2 procedures, metrics, and incident responses.
- `../db/README.md` — roles, migrations, what's safe to drop.

## If you are deciding something
- `adr/README.md` → the relevant `adr/NNNN-*.md`. Don't relitigate an Accepted decision; if it's
  wrong, supersede it with a new ADR and update the invariant it produced.

## Map of the tree
```
README.md                     tier-by-tier file inventory
CLAUDE.md / AGENTS.md         agent entry point (+ cross-tool pointer)
BACKLOG.md                    phased, test-provable task list
openapi/                      ariadne-api.yaml, ariadne-tools.yaml
schemas/                      state-doc, extractor-output
prompts/                      extractor.md
specs/                        context-pack.md, queue-messages.md
db/                           README.md, migrations/0001..0006
fixtures/openwebui/           payload shapes + capture recipe
eval/                         run.py, pack/, extraction/, resume/
security/                     abuse-cases.md
docs/                         architecture.md, INDEX.md, GLOSSARY.md, INVARIANTS.md,
                              open-webui-integration.md, test-strategy.md,
                              config-reference.md, runbook.md,
                              adr/, component-specs/, diagrams/
```
