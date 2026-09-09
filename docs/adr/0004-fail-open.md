# ADR-0004: Fail open — Ariadne is never in a chat's critical path

**Status:** Accepted

## Context
Ariadne augments conversations. If augmentation could break or delay a reply, the feature would
be worse than not having it, and users would disable it.

## Decision
Every interaction with Ariadne from the filter is **best-effort**: a hard client timeout
(≤ 400 ms on the pack), try/except around every call, and turn-shipping as fire-and-forget
(`202`). On any error or timeout the filter returns the chat request unchanged.

## Alternatives rejected
- **Block the turn until the pack is ready** — turns a slow dependency into a broken chat.
- **Retry synchronously in the filter** — adds latency to the exact path we must keep fast.

## Consequences
- The service may serve a stale or empty pack under load; that is acceptable and surfaced via
  `stale_turns` and `cache` in the response.
- All heavy work (persist, embed, extract, summarize) is asynchronous behind the queue (ADR-0009).
- `readyz` reflects dependency health so orchestration can react, but the chat path never depends
  on it.
- This is the top invariant (INV-1); every component change is checked against it.

## Produces / relates to
INV-1 · `docs/open-webui-integration.md` §1.5, `openapi/ariadne-api.yaml` (`/v1/context-pack`, `/v1/turns`)
