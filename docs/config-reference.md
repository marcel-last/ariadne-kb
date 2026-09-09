# Configuration reference

Every knob Ariadne reads, with its default and which component reads it. This is the
authoritative list; the specs quote individual values but defaults live **here**, and the numbers
must agree (the "must match" note at the end lists the cross-references). No component reads
`os.environ` directly — everything goes through `ariadne_common.config` (see
`docs/component-specs/common.md`).

Three kinds of configuration:
- **Env vars** — service configuration, set on the container. Secrets are marked 🔒.
- **Open WebUI settings** — not Ariadne's, but required on the Open WebUI side for the tool
  surface and turn capture to work (`docs/open-webui-integration.md`).
- **Valves / UserValves** — Open WebUI filter settings; and **per-project policy flags** stored in
  the DB.

Types: `s` = seconds, `tok` = tokens.

## Core / shared (all services, via `ariadne_common`)

| Name | Default | Read by | Purpose |
|---|---|---|---|
| `DATABASE_URL` 🔒 | — (required) | api, worker, tools, reconciler | Postgres DSN. Runtime services connect as `ariadne_app` (non-superuser); migrations use `ariadne_migrate` (`db/README.md`). |
| `REDIS_URL` 🔒 | `redis://redis:6379/0` | api, worker | Cache, streams, locks. |
| `OBJECT_STORE_ENDPOINT` | `http://minio:9000` | api, worker | S3-compatible endpoint for T4 artifact blobs. |
| `OBJECT_STORE_BUCKET` | `ariadne` | api, worker | Bucket/prefix root for artifacts. |
| `OBJECT_STORE_KEY` 🔒 | — (required) | api, worker | Object-store access key. |
| `OBJECT_STORE_SECRET` 🔒 | — (required) | api, worker | Object-store secret key. |
| `IDENTITY_HMAC_SECRET` 🔒 | — (required) | filter, api, tools, reconciler | Shared secret that signs/verifies `X-Ariadne-Identity` (HS256). Must be identical across the filter and the services. |
| `IDENTITY_CLAIM_TTL_S` | `300` | filter, tools, reconciler (mint); api (verify) | Identity-claim lifetime. **Hard cap 300 s** — INV-12 rejects anything longer regardless of this value. |
| `LOG_LEVEL` | `INFO` | all | Structured-log level. Never log secrets or full message bodies at `INFO`. |

## Filter (runs inside Open WebUI)

Set as filter **Valves** (or env, if you vendor the filter). See `docs/component-specs/filter.md`.

| Name | Default | Purpose |
|---|---|---|
| `ARIADNE_URL` | `http://ariadne-api:8080` | Base URL the filter calls. |
| `ARIADNE_API_KEY` 🔒 | — (required) | Per-tenant service key sent as `X-Ariadne-Key`; the tenant is derived from it. |
| `INLET_TIMEOUT_S` | `0.4` | Hard timeout on `POST /v1/context-pack`. On timeout the filter injects nothing and the chat proceeds — INV-1. Keep ≤ 0.4 s. |
| `OUTLET_TIMEOUT_S` | `2.0` | Timeout on the fire-and-forget `POST /v1/turns`. Not user-facing latency; a miss is caught by the reconciler (ADR-0008). |
| `PACK_BUDGET_TOKENS` | `4000` | Requested pack budget (`ContextPackRequest.budget_tokens`); the builder never exceeds it unless P0 alone does — INV-9. |
| `priority` (Valve) | `0` | Open WebUI filter execution order; lower runs first. |

**UserValves** (per-user, forwarded from Open WebUI):

| Name | Default | Purpose |
|---|---|---|
| `default_project` | `""` (empty) | Slug to bind new chats to; empty means an implicit per-chat project. |
| `auto_bind_folders` | `true` | Use the Open WebUI `folder_id` → project map when resolving a new chat (inlet only). |
| `inject_mode` | `system` | `system` (merge into the single system message) or `user_prefix`. |

## API & pack builder (`ariadne_api`)

| Name | Default | Purpose |
|---|---|---|
| `PACK_CACHE_TTL` | `90` (s) | Whole-pack cache TTL (`specs/context-pack.md` §5). |
| `BIND_CACHE_TTL` | `300` (s) | Cached chat→project binding TTL (`specs/queue-messages.md` §7). |
| `DIGEST_MAX_TOKENS` | `400` (tok) | Cap on the P2 digest section of the pack. |
| `RECALL_W_VEC` | `1.0` | Vector weight in recall fusion (`specs/context-pack.md` §4). |
| `RECALL_W_LEX` | `0.8` | Lexical weight in recall fusion. |
| `RECALL_W_SAL` | `0.2` | Salience weight in recall fusion. |
| `RECALL_RRF_K0` | `60` | Reciprocal-rank constant `k0` in fusion. |
| `RATE_LIMIT_RPS` | `20` | Per-principal request rate before `429` (tune per deployment). |
| `INGEST_MAX_BODY_BYTES` | `262144` | Max `/v1/turns` body before `413`. |

## Worker (`ariadne_worker`)

| Name | Default | Purpose |
|---|---|---|
| `EXTRACTOR_MODEL` | — (required) | Model id for the extraction stage; use JSON-mode/grammar-constrained decoding (`prompts/extractor.md`). |
| `EMBEDDING_MODEL` | — (required) | Embedding model id. |
| `EMBEDDING_ENDPOINT` 🔒 | — (required) | Embedding API base URL (+ key if the provider needs one). |
| `EMBEDDING_DIM` | `1024` | Embedding dimension. **Must equal** the `vector(N)` column in `db/migrations/0004_memory.sql`; changing it needs a migration + re-embed (`db/README.md`). |
| `INGEST_MAX_ATTEMPTS` | `5` | Deliveries before an entry goes to `ariadne:dlq` (`specs/queue-messages.md` §4). |
| `INGEST_STREAM_MAXLEN` | `1000000` | Approx `XADD MAXLEN` trim for `ariadne:ingest`; safe because acked turns are already in Postgres. |
| `INGEST_LAG_ALERT` | `5000` | Ingest backlog at which `ariadne_ingest_lag` is considered high (runbook). |
| `SUMMARY_SEGMENT_TURNS` | `20` | Turns per segment before a T2 roll-up (or on an extractor segment-boundary hint). |
| `EXTRACTOR_MAX_RETRIES` | `1` | Extra attempts on invalid extractor output before deferring T1 (INV-13). |
| `STREAM_MIN_IDLE_MS` | `60000` | `XAUTOCLAIM` reclaim threshold for stuck entries. |

## Tools (`ariadne_tools`)

Inherits `IDENTITY_HMAC_SECRET`, `IDENTITY_CLAIM_TTL_S`, and an `ARIADNE_URL` to reach the API.

| Name | Default | Purpose |
|---|---|---|
| `ARIADNE_URL` | `http://ariadne-api:8080` | API base the tool server proxies to (via `@chat:<id>`). |
| `ARIADNE_API_KEY` 🔒 | — (required) | Service key for the proxied API calls. |
| `TOOLS_REQUIRE_CHAT_HEADER` | `true` | If a call lacks a resolvable chat id, fail closed with 428 — INV-3. Do **not** set false. |

## Reconciler (`ariadne_reconciler`)

| Name | Default | Purpose |
|---|---|---|
| `OPENWEBUI_URL` | — (required) | Base URL of the Open WebUI instance to read chats from. |
| `OPENWEBUI_API_KEY` 🔒 | — (required) | Admin/service-account key to read the chat REST API. |
| `RECONCILE_INTERVAL_S` | `300` (s) | How often to scan for turns `outlet` missed (ADR-0008). |
| `RECONCILE_BATCH` | `100` | Max chats processed per pass (cursored, rate-limited). |

## Open WebUI settings (not Ariadne env, but required)

Set these on the Open WebUI side; details and version-gates in `docs/open-webui-integration.md`.

| Setting | Required value | Why |
|---|---|---|
| `ENABLE_FORWARD_USER_INFO_HEADERS` | `true` (or a per-connection `{{CHAT_ID}}` header on the Ariadne tool connection) | Forwards `X-OpenWebUI-Chat-Id` + user headers so the tool server can resolve the project — INV-3. Off by default. |
| Function Calling | **Native** (not Legacy) | Multi-round tool use for the tool surface — ADR-0007. Native is the default since Open WebUI 0.10.0. |
| `ENABLE_API_OUTLET_FILTERS` | `true` (on releases that support it) | Lets `outlet` fire for direct-API callers; where unsupported, the reconciler covers the gap — ADR-0008. |

## Per-project policy flags (stored in the DB, v1 sketch)

Set per project (defaults chosen to be safe); surfaced via the project API in a later phase.

| Flag | Default | Purpose |
|---|---|---|
| `policy.redact_secrets` | `true` | Run the redaction stage before embedding — INV-10. Leave on. |
| `policy.auto_extract` | `true` | Run the extractor on ingest; off makes the project append-only (T0 + recall, no auto-brief). |
| `policy.recall_enabled` | `true` | Include the query-dependent recall slot in packs for this project. |
| `template` | `default` | State-doc template; only `default` in v1. |

## Defaults that MUST match elsewhere (consistency)
These values are stated in more than one place; if you change one, change all:
- `EMBEDDING_DIM` (1024) == `vector(N)` in `db/migrations/0004_memory.sql` and the `db/README.md` note.
- `PACK_CACHE_TTL` (90 s), `BIND_CACHE_TTL` (300 s), `INGEST_STREAM_MAXLEN`, `INGEST_MAX_ATTEMPTS`
  (5), `SUMMARY_SEGMENT_TURNS` (20), `STREAM_MIN_IDLE_MS` (60000) == `specs/queue-messages.md`.
- `PACK_BUDGET_TOKENS` (4000), `DIGEST_MAX_TOKENS` (400), `RECALL_W_*`, `RECALL_RRF_K0` (60) ==
  `specs/context-pack.md`.
- `INLET_TIMEOUT_S` (0.4) == the 400 ms budget in `docs/INVARIANTS.md` INV-1 and `docs/architecture.md`.
- `IDENTITY_CLAIM_TTL_S` (300) == the ≤ 300 s cap in INV-12 / ADR-0005.
