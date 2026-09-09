# Queue & message specification

**Transport:** Redis Streams (+ consumer groups). **Producers:** `ariadne-api`.
**Consumers:** `ariadne-worker` stages. **Persistence of record:** Postgres (T0).
Redis is a work queue and cache, **not** a source of truth — it can be flushed and rebuilt
from Postgres.

This spec fixes the stream names, message shapes, delivery semantics and idempotency keys so
the API and worker agree without reading each other's code.

---

## 1. Streams and groups

| Stream | Producer | Consumer group | Purpose |
|---|---|---|---|
| `ariadne:ingest` | `POST /v1/turns` | `cg:ingest` | One entry per accepted turn; fans out to the stage pipeline. |
| `ariadne:jobs` | merge/rebuild/purge/export endpoints | `cg:jobs` | Long-running project operations. |
| `ariadne:dlq` | worker (on give-up) | — (inspected by ops) | Poison messages after max retries. |

The worker runs the pipeline **stages** — `persist → embed → extract → summarize` — as
ordered steps of a single `ariadne:ingest` consumer, tracked per project in `stage_cursor`.
Stages are independent and idempotent: re-running any stage for a `seq` it already processed
is a no-op (guarded by `stage_cursor.last_seq` and by DB uniqueness).

---

## 2. `ariadne:ingest` message

Fields are Redis stream key/values (all strings; `payload` is JSON):

```json
{
  "v": "1",
  "type": "turn",
  "tenant_id": "b1e...-uuid",
  "project_id": "9f2...-uuid",
  "chat_id": "owui-chat-abc123",
  "idempotency_key": "optional-from-header",
  "correlation": { "pack_id": "6f1c...", "state_version": 142, "t0": 1757400000.12 },
  "source": "filter",
  "messages": [
    { "role": "user", "content": "confirmed the IDOR ...", "owui_message_id": "m-771", "timestamp": 1757400000 },
    { "role": "assistant", "content": "Nice, marking it confirmed.", "owui_message_id": "m-772" }
  ]
}
```

The API resolves `project_id` (via the chat binding) **before** enqueuing — the worker never
does project resolution. `messages` is already normalized (content-part arrays flattened to
text where possible; non-text parts replaced by references).

### content_hash (idempotency)
For each message the worker computes:

```
content_hash = sha256( canonical_json({
    "chat_id": chat_id,
    "role": role,
    "key": owui_message_id or sha256(content_text)
}) )
```

`canonical_json` = UTF-8, sorted keys, no insignificant whitespace. Insert into `event` with
`ON CONFLICT (project_id, content_hash) DO NOTHING`. This makes outlet POSTs and reconciler
backfill converge: whichever arrives first wins, the other is absorbed. `TurnAccepted.deduplicated`
is true when every message in the turn already existed.

---

## 3. Stage pipeline

Each stage advances `stage_cursor(project_id, stage)` to the max `seq` it has completed.

1. **persist** — assign per-project `seq` and insert `event` rows (T0). Seq assignment uses
   the Redis lock `ariadne:lock:seq:{project_id}` (see §5); if Redis is unavailable, falls back
   to `SELECT ariadne_next_seq(project_id)` under a Postgres advisory lock. Persist is the only
   stage that assigns `seq`; downstream stages read it. **Ordering is enforced here**: a turn's
   events get contiguous seqs in message order.
2. **embed** — for new `event`s that yield memories/chunks, compute embeddings in batches and
   fill `memory.embedding`. Failure here never blocks extract; embeddings backfill on retry or
   `rebuild --stages embed`.
3. **extract** — run the extractor prompt (`prompts/extractor.md`) over the new turn + current
   state, validate against `schemas/extractor-output.schema.json`, apply the patch (optimistic
   concurrency on `state_doc.version`), index `memories`. On patch rejection keep memories, skip
   T1 (see prompt §failure handling).
4. **summarize** — when a segment boundary is hit (extractor hint) or every `SUMMARY_SEGMENT_TURNS`
   (default 20) turns, roll up a `summary` row; periodically roll segment→session→project.

A single consumer processes a given `project_id`'s turns in `seq` order (partition by project;
see §5) so extract always sees a consistent, current state document.

---

## 4. Delivery semantics

- **At-least-once.** `XREADGROUP` → process → `XACK`. A crash before `XACK` re-delivers.
- **Reclaim.** A reaper runs `XAUTOCLAIM ariadne:ingest cg:ingest <consumer> min-idle-time
  60000` to steal entries stuck in another consumer's PEL (Pending Entries List).
- **Retries.** Per-entry attempt count tracked in a companion hash
  `ariadne:attempts:{stream_entry_id}` (TTL 1 h). On the `INGEST_MAX_ATTEMPTS`-th failure
  (default 5), the entry is written to `ariadne:dlq` with the last error and `XACK`ed off the
  main stream. Idempotency (content_hash, stage_cursor) makes retries safe.
- **Poison isolation.** DLQ entries never block the stream. Ops replays them with
  `ariadne:jobs`→`rebuild --from_seq` after a fix.

Because every stage is idempotent, at-least-once delivery yields effectively-once *effects*.

---

## 5. Ordering & locking

Per-project ordering is the only ordering that matters (projects are independent).

- **Seq assignment / write serialization:** `SET ariadne:lock:seq:{project_id} <token> NX PX 5000`
  (a Redlock-style single-instance lock; token checked on release via a Lua CAS). Held only for
  the persist stage's insert, not across LLM calls. Postgres advisory lock is the fallback and
  the ultimate arbiter of `seq` (it increments `project.last_seq`), so even a mis-behaving Redis
  lock cannot create duplicate seqs — the `UNIQUE(project_id, seq)` constraint is the backstop.
- **Extract serialization:** the optimistic `base_version` check on `state_doc` means two
  concurrent extracts for one project can't both commit; the loser retries against the new
  version. Partitioning by project avoids that cost in the normal case.

---

## 6. `ariadne:jobs` message

```json
{
  "v": "1",
  "job_id": "uuid",
  "kind": "rebuild",              // merge | rebuild | purge | export
  "tenant_id": "uuid",
  "project_id": "uuid",
  "args": { "stages": ["embed","extract","summarize"], "from_seq": 0 }
}
```

The worker updates the `job` row (`status`, `progress{done,total,stage}`) as it goes; clients
poll `GET /v1/jobs/{id}`. `purge` deletes all tiers for the project (and its object-store
prefix) then the `project` row; it is irreversible and audit-logged. `export` streams a zip to
the object store and returns a signed URL in `job.result`.

---

## 7. Key & channel conventions

| Key | Meaning | TTL |
|---|---|---|
| `ariadne:lock:seq:{project_id}` | persist-stage write lock | 5 s (auto-expire) |
| `ariadne:attempts:{entry_id}` | retry counter | 1 h |
| `ariadne:pack:{project_id}:{state_version}:{tokenizer}` | rendered non-recall pack block | until version change |
| `ariadne:pack:{project_id}:{state_version}:{budget}:{tokenizer}:{query_hash}:{k}` | whole pack | `PACK_CACHE_TTL` (90 s) |
| `ariadne:bind:{chat_id}` | cached chat→project binding | `BIND_CACHE_TTL` (300 s) |

Cache invalidation on state change deletes the `ariadne:pack:{project_id}:*` set via a
version bump (we never scan keyspace: bumping `state_version` makes old keys unreachable and
they expire). Binding cache is deleted explicitly on `bind`/`rebind`.

---

## 8. Backpressure & limits

- `XADD ... MAXLEN ~ INGEST_STREAM_MAXLEN` (default 1e6) caps the stream; trimming is safe
  because acked+persisted turns are already in Postgres.
- If ingest lag (`XLEN` minus group PEL) exceeds `INGEST_LAG_ALERT` (default 5000), emit the
  `ariadne_ingest_lag` metric high and (optionally) shed the embed stage first (it backfills).
- The API's `/v1/turns` is fire-and-forget for the filter; if Redis `XADD` fails, the API
  returns 202 only after a synchronous fallback insert into `event` (persist inline) so a turn
  is never lost when the queue is down — degraded, not dropped.
