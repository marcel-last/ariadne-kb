# ADR-0002: Integrate via an Open WebUI Filter function

**Status:** Accepted

## Context
Ariadne must inject context on the way in and capture turns on the way out of every relevant
chat, across arbitrary models, without forking Open WebUI. Open WebUI offers several extension
points (see `docs/open-webui-integration.md`).

## Decision
Use a **Filter function** as the required touchpoint: `inlet` fetches and injects the context
pack; `outlet` ships the completed turn. Add the `ariadne-tools` OpenAPI tool server as a
recommended second touchpoint for deliberate, model-driven memory operations. Read the chat REST
API only from the reconciler.

## Alternatives rejected
- **Pipelines** — the docs now mark Pipelines legacy and steer to in-process Functions; a filter
  needs no separate worker container.
- **DB change-data-capture on Open WebUI's tables** — couples us to their schema, misses the
  injection direction entirely, and is fragile across upgrades.
- **Open WebUI native memory** — not model-agnostic in the way we need, and not a project-scoped
  continuity model.
- **Wrapping the model endpoint (a Pipe/proxy)** — would put Ariadne in the critical path,
  conflicting with ADR-0004.

## Consequences
- Injection is once-per-turn in `inlet`; `request` (per provider call) is deliberately not used
  in v1 (`docs/open-webui-integration.md` §1.4).
- `outlet` does not fire for direct-API callers on tagged releases → the reconciler is mandatory
  (ADR-0008).
- The pack must be rendered deterministically and within a tight latency budget so `inlet` stays
  cheap (INV-8, INV-9).
- We depend on documented filter behaviour (dunder params, `__metadata__` correlation), pinned in
  `docs/open-webui-integration.md`.

## Produces / relates to
INV-1, INV-8, INV-9 · `docs/open-webui-integration.md`, `specs/context-pack.md`, `openapi/ariadne-tools.yaml`
