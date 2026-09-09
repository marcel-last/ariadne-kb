-- 0002_events.sql — T0 event log (the source of truth) + per-project sequence
-- INVARIANT (see INVARIANTS.md): T0 is append-only and is the ONLY source of truth;
-- T1/T2/T3 are projections rebuildable from it. Nothing here is ever UPDATEd or DELETEd
-- except by an explicit project purge.

BEGIN;

CREATE TABLE event (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- physical order only
    tenant_id     uuid   NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    project_id    uuid   NOT NULL REFERENCES project(id) ON DELETE CASCADE,
    chat_id       text   REFERENCES session(chat_id) ON DELETE SET NULL,
    seq           bigint NOT NULL,     -- per-project, gap-free, assigned by the worker
    kind          text   NOT NULL CHECK (kind IN
                    ('user_msg','assistant_msg','tool_call','tool_result','state_patch','system')),
    role          text,
    body          jsonb  NOT NULL,     -- {text | json | blob_ref, tokens, ...}
    content_hash  bytea  NOT NULL,     -- sha256 over normalized body; dedupe/idempotency
    owui_message_id text,
    source        text   NOT NULL DEFAULT 'filter'
                    CHECK (source IN ('filter','reconciler','import','merge')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    -- gap-free ordering per project (defines summary/rebuild boundaries)
    UNIQUE (project_id, seq),
    -- makes ingestion idempotent: outlet POST and reconciler backfill can both insert;
    -- the second is absorbed by ON CONFLICT DO NOTHING in the worker.
    UNIQUE (project_id, content_hash)
);
CREATE INDEX event_by_project_id  ON event (project_id, id);
CREATE INDEX event_by_project_seq ON event (project_id, seq);
CREATE INDEX event_by_chat        ON event (chat_id) WHERE chat_id IS NOT NULL;

COMMENT ON COLUMN event.seq IS
  'Per-project monotonic, gap-free sequence assigned by the worker under a Redis lock '
  '(fallback: pg_advisory_xact_lock on hashtextextended(project_id::text, 0)). Do not '
  'derive from event.id.';

-- Advisory-lock helper so the worker can assign seq transactionally if Redis is down.
-- Usage (worker): SELECT ariadne_next_seq(:project_id);  -- within the INSERT txn
CREATE FUNCTION ariadne_next_seq(p_project uuid) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
    v_seq bigint;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(p_project::text, 0));
    UPDATE project SET last_seq = last_seq + 1, updated_at = now()
      WHERE id = p_project
      RETURNING last_seq INTO v_seq;
    IF v_seq IS NULL THEN
        RAISE EXCEPTION 'ariadne_next_seq: unknown project %', p_project
          USING ERRCODE = 'foreign_key_violation';
    END IF;
    RETURN v_seq;
END;
$$;

COMMIT;
