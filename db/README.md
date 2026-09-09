# Database

PostgreSQL 17 + [pgvector](https://github.com/pgvector/pgvector) ≥ 0.7. Migrations are plain
SQL under `migrations/`, forward-only, applied in filename order. They are written for
[`dbmate`](https://github.com/amacneil/dbmate) but are tool-agnostic (each is a self-contained
`BEGIN…COMMIT`).

## Roles

Two roles, deliberately separated so RLS is meaningful (see `migrations/0006_rls.sql`):

- **`ariadne_migrate`** — owns the schema; runs migrations. May be superuser in dev.
- **`ariadne_app`** — the role the API/worker connect as at runtime. **Not** superuser, **not**
  `BYPASSRLS`. RLS policies apply to it, so a query that forgets a `WHERE tenant_id=…` still
  cannot cross tenants.

```sql
-- bootstrap (run once as a superuser)
CREATE ROLE ariadne_migrate LOGIN PASSWORD '...';
CREATE ROLE ariadne_app     LOGIN PASSWORD '...';
CREATE DATABASE ariadne OWNER ariadne_migrate;
-- extensions need elevated rights; created inside 0001 but the role must be allowed:
GRANT ALL ON DATABASE ariadne TO ariadne_migrate;
```

After migrating, grant runtime privileges to `ariadne_app` (DML only, no DDL):

```sql
GRANT USAGE ON SCHEMA public TO ariadne_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ariadne_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ariadne_app;
ALTER DEFAULT PRIVILEGES FOR ROLE ariadne_migrate IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ariadne_app;
```

## Running

```bash
export DATABASE_URL="postgres://ariadne_migrate:...@localhost:5432/ariadne?sslmode=disable"
dbmate --migrations-dir ./migrations up      # apply all
dbmate --migrations-dir ./migrations status  # show pending/applied
```

`/readyz` reports `migrations_current` by comparing the highest applied migration to the files
present; keep the check in sync if you switch migration tools.

## Per-request tenant scoping

The API must set the tenant GUC inside every request transaction, from the verified identity
claim — never from request input:

```sql
SET LOCAL ariadne.tenant = '<tenant-uuid>';
```

All tenant-scoped tables self-filter on it via RLS. Forgetting it means queries see **no**
rows (fail-closed), which is the intended safety property.

## Embedding dimension

`memory.embedding` is `vector(1024)`, matching the default embedding model
(`EMBEDDING_DIM=1024`, see `docs/config-reference.md`). Changing models with a different
dimension requires: a migration altering the column type, then
`POST /v1/projects/{id}/rebuild {"stages":["embed"]}` per project (or a global re-embed job).
The HNSW index is **partial** (`WHERE valid AND embedding IS NOT NULL`) so unembedded or
superseded rows cost nothing.

## What is safe to drop

Everything except `event` (T0) is a projection. In a pinch you can `TRUNCATE`
`state_doc, state_doc_history, checkpoint, summary, memory, stage_cursor` and replay with a
full `rebuild`; the brief, summaries and memory index reconstruct deterministically from the
event log. Never truncate `event`, `project`, `tenant`, `app_user`, `session` — those are
authoritative.
