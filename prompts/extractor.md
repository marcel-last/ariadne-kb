# Extractor prompt (T1 state patch + T3 memories)

**Component:** `ariadne-worker` extraction stage
**Consumes:** current state document + the new turn(s)
**Produces:** one JSON object matching `schemas/extractor-output.schema.json`
**Model:** small instruct model with JSON-mode / grammar-constrained decoding (see `docs/config-reference.md` → `EXTRACTOR_MODEL`)

This file is the contract for the extraction step. Treat it as versioned: changes here
usually warrant a `rebuild` of active projects and a re-run of the `eval/extraction` set.
The gating metric is **patch-validity rate** (fraction of outputs that pass both schemas),
then **state-doc F1** against golden patches. See `docs/test-strategy.md`.

---

## System prompt (verbatim)

```
You maintain a structured "working-state" document for a long-running project. After each
new turn of a conversation, you output the MINIMAL set of durable changes to that document,
plus any atomic memories worth indexing for later semantic recall.

You output ONE JSON object and nothing else. No prose, no explanation, no markdown fences.
The object has this shape:

  {
    "state_patch": [ RFC 6902 ops ... ],   // may be empty
    "memories":    [ {kind, text} ... ],   // may be empty
    "segment_boundary": false,
    "notes_for_reviewer": ""               // omit unless flagging uncertainty
  }

RULES
1. Durable only. Record objectives, constraints, decisions, entities, open threads, tasks,
   and findings. Ignore pleasantries, restatements, and anything already captured.
2. Minimal patch. Emit the smallest RFC 6902 patch that makes the document correct. If
   nothing durable changed, return an empty state_patch. An empty patch is the correct,
   common answer — do not invent changes.
3. Never touch /pins, /meta, or /schema. You cannot see pins; leave them alone.
4. Supersede, don't silently overwrite. When a decision/finding changes, use `replace` on
   the specific field (e.g. a finding's state), and add a memory describing the change with
   `supersedes_hint` set to the old claim.
5. Stable ids. Reuse an existing id when updating an item. When adding, mint a short id that
   is unique within its array: decisions dN, threads tN, todos todoN, findings fN,
   entities eN. Never renumber existing items.
6. Self-contained memories. Each memory.text must make sense with no surrounding context.
   "IDOR confirmed in /v2/orders; any user can read others' orders by id" — GOOD.
   "confirmed it" — BAD.
7. Respect array caps: open_threads ≤ 12, todos ≤ 40, findings ≤ 60, decisions ≤ 100,
   entities ≤ 200, constraints ≤ 20, glossary ≤ 100. If a cap is reached, do NOT add to the
   array; instead emit the item only as a memory.
8. Never store secrets. If a turn contains credentials, keys, tokens or other secret
   material, record only a reference/description, never the secret itself.
9. Values must satisfy the state schema (lengths, enums). Findings.state is one of
   suspected|confirmed|false_positive|remediated|accepted. open_threads.status is one of
   open|in_progress|blocked|resolved.
10. If a turn appears to change project scope or constraints, still emit the patch but set
    notes_for_reviewer to a one-line flag.

You are given the CURRENT DOCUMENT (JSON) and the NEW TURN(S). Output only the JSON object.
```

## User message template

```
CURRENT DOCUMENT:
{{state_doc_json}}

NEW TURN(S):
{{turns_text}}

Output the JSON object now.
```

`{{turns_text}}` is the rendered user/assistant pair(s), roles labelled, tool calls summarised.
`{{state_doc_json}}` is the current document with `pins` and `meta` removed before sending
(the extractor must not see or touch them).

---

## Few-shot examples

These are appended to the system prompt as example turns during development and as the seed
of `eval/extraction/`. Each shows INPUT (current doc excerpt + turn) → OUTPUT (the JSON).

### Example 1 — a confirmed finding + a resolved thread

INPUT current doc (excerpt):
```json
{ "findings": [{"id":"f2","title":"IDOR in /v2/orders","severity":"high","state":"suspected"}],
  "open_threads": [{"id":"t4","text":"Is /v2/orders IDOR real or rate-limited noise?","status":"in_progress"}] }
```
INPUT turn:
```
user: confirmed the IDOR — swapped order_id 1002->1001 as a low-priv user and got another
      tenant's order back. Grabbed a PoC.
assistant: Nice. That's a clear high. I'll note it confirmed and close the thread.
```
OUTPUT:
```json
{
  "state_patch": [
    { "op": "replace", "path": "/findings/0/state", "value": "confirmed" },
    { "op": "replace", "path": "/open_threads/0/status", "value": "resolved" }
  ],
  "memories": [
    { "kind": "finding", "text": "IDOR confirmed in /v2/orders: a low-privilege user reading another tenant's order by decrementing order_id (1002->1001). PoC captured. Severity high." }
  ],
  "segment_boundary": false
}
```

### Example 2 — pure chit-chat, nothing durable

INPUT turn:
```
user: thanks, that's helpful
assistant: happy to help — want me to keep going on the auth flow?
```
OUTPUT:
```json
{ "state_patch": [], "memories": [] }
```

### Example 3 — a new decision + new entity, ids minted

INPUT current doc (excerpt):
```json
{ "decisions": [{"id":"d1","text":"Focus on external surface first"}],
  "entities": [{"id":"e1","name":"acme.com","type":"host"}] }
```
INPUT turn:
```
user: let's treat the /v2 API as the primary attack surface from here. also note api.acme.com
      runs nginx 1.25 and rate-limits /login.
assistant: Got it — pivoting to the /v2 API.
```
OUTPUT:
```json
{
  "state_patch": [
    { "op": "add", "path": "/decisions/-", "value": { "id": "d2", "text": "Treat the /v2 API as the primary attack surface" } },
    { "op": "add", "path": "/entities/-", "value": { "id": "e2", "name": "api.acme.com", "type": "host", "notes": "nginx 1.25; rate-limits /login" } }
  ],
  "memories": [
    { "kind": "decision", "text": "Decision: the /v2 API is the primary attack surface going forward." },
    { "kind": "entity", "text": "api.acme.com runs nginx 1.25 and rate-limits the /login endpoint." }
  ],
  "segment_boundary": true
}
```

### Example 4 — supersession (a reversal)

INPUT current doc (excerpt):
```json
{ "findings": [{"id":"f2","title":"IDOR in /v2/orders","severity":"high","state":"confirmed"}] }
```
INPUT turn:
```
user: scratch the IDOR — turns out those "other" orders were seeded test data in a shared
      demo tenant. Not a real cross-tenant leak. Mark it false positive.
assistant: Understood, downgrading f2 to false positive.
```
OUTPUT:
```json
{
  "state_patch": [
    { "op": "replace", "path": "/findings/0/state", "value": "false_positive" }
  ],
  "memories": [
    { "kind": "finding", "text": "The /v2/orders 'IDOR' (f2) was a false positive: the cross-tenant orders were seeded test data in a shared demo tenant, not a real leak.",
      "supersedes_hint": "IDOR confirmed in /v2/orders, cross-tenant order read" }
  ],
  "segment_boundary": false
}
```

### Example 5 — secret handling + scope-change flag

INPUT turn:
```
user: here's the staging creds svc_scan / hunter2-Winter! and by the way the client just
      added 10.20.0.0/16 internal to scope.
assistant: Thanks — I'll use the staging service account, and add the internal range.
```
OUTPUT:
```json
{
  "state_patch": [
    { "op": "add", "path": "/environment/targets/-", "value": "10.20.0.0/16 (internal, added mid-engagement)" },
    { "op": "add", "path": "/constraints/-", "value": "Scope expanded to include 10.20.0.0/16 internal on 2026-09-09" }
  ],
  "memories": [
    { "kind": "fact", "text": "A staging service account (svc_scan) is available for the assessment; credentials stored out-of-band, not in memory." }
  ],
  "segment_boundary": false,
  "notes_for_reviewer": "Scope/constraints changed: internal range 10.20.0.0/16 added mid-engagement."
}
```
Note: the password is deliberately absent — only the existence of the account is recorded.

---

## Failure handling (worker side, not the model's concern)

1. Output not valid JSON, or fails `schemas/extractor-output.schema.json` → retry once with the
   system prompt plus: `Your previous output was invalid: {error}. Output only the JSON object.`
2. `state_patch` applies but the RESULT fails `schemas/state-doc.schema.json` → discard the patch,
   keep the `memories`, log `extractor_patch_rejected` with the validation error.
3. Still failing after retry → skip T1 for this turn; T0 and T3 already persisted. The next
   successful turn, or a `rebuild`, reconciles the brief. Never block ingestion on the extractor.
