-- 0001_init.sql — extensions, tenancy, projects, sessions
-- Ariadne schema. Target: PostgreSQL 17 with the `vector` (pgvector >= 0.7) extension.
-- Migrations are forward-only and ordered by filename. Each file is idempotent where cheap
-- to make re-runs on a fresh dev DB painless, but production runs each exactly once.
--
-- Conventions:
--   * All tenant-scoped tables carry tenant_id and enable RLS (see 0006_rls.sql).
--   * Timestamps are timestamptz, default now(), UTC.
--   * uuid PKs via gen_random_uuid() (pgcrypto).

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS vector;     -- pgvector

-- Schema version marker used by /readyz (migrations_current) and rebuild logic.
CREATE TABLE schema_meta (
    key         text PRIMARY KEY,
    value       text NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
INSERT INTO schema_meta(key, value) VALUES ('state_doc_schema', 'ariadne.state/1');

CREATE TABLE tenant (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name        text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app_user (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    owui_user_id  text NOT NULL,             -- Open WebUI user id (from identity claim `sub`)
    email         text,
    display_name  text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, owui_user_id)
);

CREATE TABLE project (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    owner_id       uuid NOT NULL REFERENCES app_user(id) ON DELETE RESTRICT,
    slug           text NOT NULL,
    title          text,
    status         text NOT NULL DEFAULT 'active'
                     CHECK (status IN ('active','archived','purging')),
    template       text NOT NULL DEFAULT 'default',
    state_version  integer NOT NULL DEFAULT 0,
    last_seq       bigint  NOT NULL DEFAULT 0,   -- highest event.seq assigned (see 0002)
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT project_slug_fmt CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
    UNIQUE (tenant_id, owner_id, slug)
);
CREATE INDEX project_by_tenant_status ON project (tenant_id, status);

-- Access control. The owner also gets a row here for uniform checks.
CREATE TABLE project_acl (
    project_id  uuid NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    user_id     uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
    role        text NOT NULL CHECK (role IN ('owner','editor','viewer')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, user_id)
);

-- One row per Open WebUI chat. chat_id is the natural key.
CREATE TABLE session (
    chat_id          text PRIMARY KEY,
    tenant_id        uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    project_id       uuid NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    bound_by         text NOT NULL DEFAULT 'implicit'
                       CHECK (bound_by IN ('existing','command','folder','default','implicit','api')),
    bound_at         timestamptz NOT NULL DEFAULT now(),
    binding_history  jsonb NOT NULL DEFAULT '[]'::jsonb   -- [{project_id, from, to}]
);
CREATE INDEX session_by_project ON session (project_id);

-- Optional folder→project map for Open WebUI folder auto-binding (architecture §5.3).
CREATE TABLE folder_binding (
    tenant_id   uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    folder_id   text NOT NULL,
    project_id  uuid NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, folder_id)
);

COMMIT;
