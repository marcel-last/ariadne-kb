-- 0005_artifacts_jobs.sql — T4 artifact metadata, async jobs, worker progress marks

BEGIN;

-- Artifact bytes live in the object store; this is metadata + the blob pointer.
CREATE TABLE artifact (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    project_id    uuid NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    name          text NOT NULL,
    blob_ref      text NOT NULL,          -- e.g. s3://bucket/tenant/project/<hash>
    content_hash  bytea NOT NULL,
    bytes         bigint NOT NULL,
    mime          text NOT NULL DEFAULT 'text/plain',
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT artifact_name_fmt CHECK (name ~ '^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$'),
    UNIQUE (project_id, name)
);

-- Async jobs surfaced via GET /v1/jobs/{id}.
CREATE TABLE job (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    project_id  uuid REFERENCES project(id) ON DELETE CASCADE,
    kind        text NOT NULL CHECK (kind IN ('merge','rebuild','purge','export')),
    status      text NOT NULL DEFAULT 'queued'
                  CHECK (status IN ('queued','running','succeeded','failed')),
    progress    jsonb NOT NULL DEFAULT '{}'::jsonb,
    error       text,
    result      jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX job_by_project ON job (project_id, created_at DESC);

-- Per-project, per-stage high-water marks so worker stages resume without redoing work
-- (INVARIANT: stages are independent and idempotent; see specs/queue-messages.md).
CREATE TABLE stage_cursor (
    project_id  uuid NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    stage       text NOT NULL CHECK (stage IN ('persist','embed','extract','summarize')),
    last_seq    bigint NOT NULL DEFAULT 0,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, stage)
);

COMMIT;
