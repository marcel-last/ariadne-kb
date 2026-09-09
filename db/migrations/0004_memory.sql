-- 0004_memory.sql — T2 summaries + T3 semantic memory (hybrid search)
-- Embedding dimension is deployment-configurable. 1024 matches the default embedding model
-- (docs/config-reference.md → EMBEDDING_DIM). Changing it requires a migration + rebuild.

BEGIN;

-- ---------- T2: hierarchical summaries ----------
CREATE TABLE summary (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    project_id   uuid NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    level        text NOT NULL CHECK (level IN ('segment','session','project')),
    covers_from  bigint,   -- event.seq range (inclusive)
    covers_to    bigint,
    text         text NOT NULL,
    tokens       integer,
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX summary_lookup ON summary (project_id, level, covers_to DESC);

-- ---------- T3: semantic memory ----------
CREATE TABLE memory (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id      uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    project_id     uuid NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    kind           text NOT NULL CHECK (kind IN
                     ('fact','decision','entity','procedure','todo','finding','chunk','summary')),
    text           text NOT NULL,
    source_seq     bigint,                    -- provenance → event.seq
    chat_id        text,
    author         text NOT NULL DEFAULT 'extractor'
                     CHECK (author IN ('extractor','user','model','tool','summarizer','import')),
    pinned         boolean NOT NULL DEFAULT false,
    salience       real    NOT NULL DEFAULT 0.5,
    valid          boolean NOT NULL DEFAULT true,   -- false = superseded/forgotten
    superseded_by  bigint  REFERENCES memory(id) ON DELETE SET NULL,
    content_hash   bytea,                     -- dedupe within a project
    embedding      vector(1024),              -- null until the embed stage runs
    tsv            tsvector,
    created_at     timestamptz NOT NULL DEFAULT now(),
    last_used_at   timestamptz
);

-- ANN over LIVE memories only — keeps the index small even when the raw log is huge.
CREATE INDEX memory_ann ON memory
    USING hnsw (embedding vector_cosine_ops)
    WHERE valid AND embedding IS NOT NULL;

-- Lexical half of hybrid search.
CREATE INDEX memory_fts ON memory USING gin (tsv);

-- Common filtered scans.
CREATE INDEX memory_by_project_kind ON memory (project_id, kind) WHERE valid;
CREATE INDEX memory_pinned ON memory (project_id) WHERE valid AND pinned;
CREATE UNIQUE INDEX memory_dedupe ON memory (project_id, content_hash)
    WHERE content_hash IS NOT NULL;

-- Keep tsv in sync automatically (generated tsvector needs an immutable config; we set it
-- via trigger so the language can be changed without a migration).
CREATE FUNCTION memory_tsv_update() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.tsv := to_tsvector('english', COALESCE(NEW.text, ''));
    RETURN NEW;
END;
$$;
CREATE TRIGGER memory_tsv_biu
    BEFORE INSERT OR UPDATE OF text ON memory
    FOR EACH ROW EXECUTE FUNCTION memory_tsv_update();

COMMIT;
