# ADR-0007: Require Open WebUI Native function calling for the tool surface

**Status:** Accepted

## Context
`ariadne-tools` needs the model to call tools reliably and in multiple rounds within one turn
(recall → remember → answer). Open WebUI has two modes: **Native** (agentic, the default since
v0.10.0) and **Legacy** (prompt-injection, renamed from "Default", now unsupported by Open WebUI
with no built-in tools).

## Decision
Require **Native** function calling for any model that uses the Ariadne tool surface. Document it
as a deployment precondition; treat Legacy as unsupported for tools (the filter-only pack path
still works there).

## Alternatives rejected
- **Support Legacy too** — Open WebUI itself no longer supports it for built-in tools, and it
  can't do reliable multi-round calls; maintaining a second path isn't worth it.

## Consequences
- Deployment guide states the requirement; a model forced to Legacy loses the tool surface but
  keeps injected continuity.
- Any code that inspects the mode must test `== "legacy"` and treat everything else as Native —
  an unset model no longer carries the string `"native"` (`docs/open-webui-integration.md` §4). A stale
  `== "native"` check is a known trap.

## Produces / relates to
INV-3 (tool binding) · `docs/open-webui-integration.md` §4, `openapi/ariadne-tools.yaml`
