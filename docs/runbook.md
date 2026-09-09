# Runbook

How to bring Ariadne up, run the day-2 operations, read its signals, and respond when something
is wrong. Config names are defined in `docs/config-reference.md`; behaviours referenced here are
specified in the files linked inline. The governing fact for every incident: **Ariadne fails open
(INV-1)** — when Ariadne is degraded, chats keep working *without* augmentation, so nothing here
is a user-facing outage unless Open WebUI itself is down.

## 1. Bring-up

Prereqs: Docker + compose; an Open WebUI instance; an embedding endpoint and an extractor model
endpoint reachable from the worker.

```bash
cp .env.example .env            # fill in the 🔒 secrets from config-reference.md
make up                         # postgres17+pgvector, redis, minio, api, worker, tools, reconciler
```

Bootstrap the database (once), then migrate:

```bash
# as a Postgres superuser — create roles + db (see db/README.md for the exact SQL)
make db-bootstrap
make migrate                    # dbmate up, as ariadne_migrate
make db-grant                   # runtime DML grants to ariadne_app (non-superuser)
```

Verify:

```bash
curl -fsS localhost:8080/readyz | jq   # {ready:true, checks:{postgres,redis,migrations_current,embedding_endpoint}}
```

`/readyz` must show `ready:true` and `migrations_current:true` before wiring Open WebUI. If
`migrations_current:false`, run `make migrate`.

## 2. Register with Open WebUI

Details and the version-gated caveats are in `docs/open-webui-integration.md`; the checklist:

1. **Filter:** install `integrations/openwebui/filter/ariadne_filter.py` (Admin → Functions),
   set its Valves (`ARIADNE_URL`, `ARIADNE_API_KEY`), enable it globally or per-model.
2. **Tool server:** add `ARIADNE_URL` (the tools port) under Settings → Integrations, pointing at
   `openapi/ariadne-tools.yaml`.
3. **Required settings:** `ENABLE_FORWARD_USER_INFO_HEADERS=true` **or** a per-connection
   `X-OpenWebUI-Chat-Id: {{CHAT_ID}}` header on the Ariadne tool connection; Function Calling =
   **Native**.
4. **Smoke test:** new chat → `/resume <slug>` → confirm a pack is injected; send a turn → confirm
   an `event` row appears; ask something that triggers `memory_recall`.

## 3. Day-2 operations

All are asynchronous jobs; poll `GET /v1/jobs/{id}`.

- **Rebuild** (after changing the extractor prompt or embedding model):
  `POST /v1/projects/{id}/rebuild {"stages":["embed","extract","summarize"]}`. Deterministic
  replay of T0 → T1/T2/T3; existing history is preserved, a new brief version is appended
  (INV-2). Do this per project or in a controlled batch; it costs model calls.
- **Merge** two projects: `POST /v1/projects/{id}/merge {"source_project_id":"…"}`. Replays the
  source's events into the target; source is archived (or purged with `purge_source:true`).
- **Export** a project: `GET /v1/projects/{id}/export` → zip (state, history, events, summaries,
  memories, artifacts). Use before a risky change or for portability.
- **Purge** (irreversible erasure): `DELETE /v1/projects/{id}?purge=true`. Destroys every tier +
  the object-store prefix + cache (INV-14). There is no undo — export first if unsure.
- **Checkpoint / restore** the brief: `POST …/checkpoint {"label":"…"}` then
  `POST …/restore {"label":"…"}`. Restore is non-destructive (appends a version equal to the
  snapshot).

Safe to wipe and rebuild if a projection is corrupt: `state_doc`, `state_doc_history`,
`checkpoint`, `summary`, `memory`, `stage_cursor` all rebuild from T0. **Never** truncate `event`,
`project`, `tenant`, `app_user`, `session` (`db/README.md`).

## 4. Observability

Prometheus metrics at `/metrics` on each service. Core signals:

| Metric | Meaning | Watch for |
|---|---|---|
| `ariadne_ingest_lag` | `XLEN(ariadne:ingest)` minus acked | > `INGEST_LAG_ALERT` (5000) sustained |
| `ariadne_stage_lag{stage}` | per-stage backlog (persist/embed/extract/summarize) | one stage climbing while others don't |
| `ariadne_pack_latency_seconds` (histogram) | `/v1/context-pack` time | p99 approaching 300 ms |
| `ariadne_pack_cache_ratio` | pack cache hit fraction | sudden drop (churn / cache down) |
| `ariadne_turns_ingested_total` / `_deduplicated_total` | throughput / overlap | dedup ratio spiking (reconciler double-work) |
| `ariadne_extractor_validity_ratio` | fraction of extractor outputs passing both schemas | < 0.98 (gate; `docs/test-strategy.md`) |
| `ariadne_extractor_patch_rejected_total` | applied-patch rejections | rising = prompt/model regression |
| `ariadne_dlq_depth` | `XLEN(ariadne:dlq)` | any sustained non-zero |
| `ariadne_embed_failures_total` | embedding call failures | spikes = endpoint trouble |

Also useful: the brief's `stale_turns` (per project) shows how far T1 trails T0; the
`ContextPackResponse.cache` field (`hit|miss|bypass`) for live debugging.

## 5. Alerts & responses

Each response assumes the fail-open posture: **chats are unaffected**; you are restoring
augmentation quality, not availability.

- **Ingest lag high (`ariadne_ingest_lag` > alert).** Likely the extractor or embedding endpoint
  is slow/down, or worker replicas are too few. Check `ariadne_stage_lag{stage}` to find the
  stalled stage. Actions: scale worker replicas; if it's `embed`, you can shed it temporarily (it
  backfills via `rebuild --stages embed`); persist keeps up regardless so no turns are lost
  (`specs/queue-messages.md` §8).
- **DLQ growing (`ariadne_dlq_depth` > 0).** Poison messages hit `INGEST_MAX_ATTEMPTS`. Inspect
  entries in `ariadne:dlq`; fix the cause (often a malformed body or a persistent extractor
  error), then replay with a targeted `rebuild --from_seq`. The DLQ never blocks the main stream.
- **Extractor validity dropping (`…validity_ratio` < 0.98).** A prompt or model change regressed.
  Compare against `eval/extraction` (`python eval/run.py extraction --live …`); roll back the
  prompt/model or fix, then `rebuild --stages extract` affected projects. T1 defers safely
  meanwhile (INV-13) — briefs go stale, not wrong.
- **Embedding endpoint down.** `ariadne_embed_failures_total` spikes; recall quality degrades but
  ingest continues (embed backfills later). Restore the endpoint, then
  `rebuild --stages embed` for the window affected.
- **Redis down.** The API inline-persists turns to Postgres so nothing is lost (degraded, not
  dropped — ADR-0009); packs miss cache and recompute. Restore Redis; the stream resumes. No data
  action needed.
- **Postgres down.** `/readyz` goes false; the filter fails open (no packs, no ingest) so chats
  still work. This is the one hard dependency — treat as a normal DB incident (failover/restore);
  no Ariadne-specific recovery beyond bringing it back and confirming `migrations_current`.
- **Pack latency high (p99 → 300 ms).** Check cache ratio and DB load; the builder should never do
  heavy work, so a regression here usually means a cold cache or a slow recall query. It won't
  break chats (the filter times out at 400 ms and proceeds) but it wastes the budget.

## 6. Backup & restore

- **Postgres is the only thing you must back up** — it holds T0 (the source of truth) and the
  identity tables. Standard `pg_dump`/PITR. Everything else rebuilds from it.
- **Object store** (artifacts) — back up alongside; artifacts are not reconstructable from T0.
- **Redis is disposable** — it can be flushed and rebuilt; do not treat it as state.
- **Restore drill:** restore Postgres + object store, bring services up, run `make migrate`
  (no-op if current), then optionally `rebuild` projects to refresh projections. Verify with the
  `eval/pack` golden and a `/resume` smoke test.

## 7. Upgrades

- **Ariadne code:** apply new migrations (`make migrate`); if the extractor prompt or embedding
  model changed, `rebuild` active projects (batch it). Keep `make validate-kb` green.
- **Open WebUI:** re-verify the version-gated behaviours in
  `docs/open-webui-integration.md` §6 — the `request`/`outlet` semantics, header forwarding, and
  the Native-vs-Legacy default can shift between releases. Re-capture the fixtures in
  `fixtures/openwebui/` from the upgraded instance and re-run contract tests before trusting the
  integration.
- **Embedding model change:** always a migration (if the dimension changes) + a global re-embed
  (`rebuild --stages embed`); recall quality is undefined until it completes.

## 8. Incident quick reference

| Symptom | Chats affected? | First check | Action |
|---|---|---|---|
| `/readyz` false | only augmentation | which check failed | fix that dependency |
| ingest lag high | no | `ariadne_stage_lag{stage}` | scale worker / shed embed |
| DLQ non-zero | no | `ariadne:dlq` entries | fix cause, `rebuild --from_seq` |
| briefs going stale | no | `ariadne_extractor_validity_ratio` | roll back prompt/model, `rebuild --stages extract` |
| recall poor | no | `ariadne_embed_failures_total` | restore embed endpoint, `rebuild --stages embed` |
| Redis down | no | — | restore; turns inline-persisted |
| Postgres down | augmentation only | DB health | DB failover/restore |
