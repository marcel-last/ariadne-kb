# Component specs

One spec per deployable/module. Each states what the component is responsible for, what it
consumes and produces, how it fails, and a **Definition of Done** whose every line is an
invariant check or a contract test — so "done" means *verifiable*, not "looks finished".

Read `../GLOSSARY.md` for terms, the relevant `adr/` for the decision behind a behaviour, and
`../INVARIANTS.md` for the properties every component must uphold.

| Spec | Package / path | Kind |
|---|---|---|
| [common](common.md) | `packages/ariadne_common/` | shared library |
| [api](api.md) | `packages/ariadne_api/` | service (HTTP) |
| [pack-builder](pack-builder.md) | `packages/ariadne_api/pack/` | module (hot path) |
| [worker](worker.md) | `packages/ariadne_worker/` | service (queue consumer) |
| [tools](tools.md) | `packages/ariadne_tools/` | service (HTTP, model-facing) |
| [reconciler](reconciler.md) | `packages/ariadne_reconciler/` | service (periodic) |
| [filter](filter.md) | `integrations/openwebui/filter/ariadne_filter.py` | Open WebUI plugin |

Dependency direction: `ariadne_common` is imported by every service; the **filter** imports
**nothing** from this repo (it runs inside Open WebUI — see its spec). Services talk over HTTP
and Redis, never by importing each other.
