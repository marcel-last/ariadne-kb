-- 0003_state.sql — T1 working-state document, version history, checkpoints
-- The document JSONB conforms to schemas/state-doc.schema.json (enforced in the app,
-- not by the DB — Postgres cannot cheaply express the section caps / author rules).

BEGIN;

CREATE TABLE state_doc (
    project_id  uuid PRIMARY KEY REFERENCES project(id) ON DELETE CASCADE,
    version     integer NOT NULL,
    doc         jsonb   NOT NULL,
    rendered    text,               -- cached markdown used in packs
    tokens      integer,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Every version retained for diff / restore / audit. `patch` is the RFC 6902 diff that
-- produced this version from the previous one (null for version 0 / rebuild snapshots).
CREATE TABLE state_doc_history (
    project_id  uuid    NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    version     integer NOT NULL,
    doc         jsonb   NOT NULL,
    patch       jsonb,
    author      text    NOT NULL
                  CHECK (author IN ('user','model','tool','extractor','rebuild','merge','restore')),
    reason      text,
    source_seq  bigint,
    ops         integer NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, version)
);
CREATE INDEX state_history_recent ON state_doc_history (project_id, version DESC);

CREATE TABLE checkpoint (
    project_id  uuid NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    label       text NOT NULL,
    version     integer NOT NULL,
    note        text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT checkpoint_label_fmt CHECK (label ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$'),
    PRIMARY KEY (project_id, label)
);

COMMIT;
