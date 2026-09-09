-- 0006_rls.sql — row-level security (defence in depth behind app-level authz)
-- The API sets `ariadne.tenant` per request (from the verified identity claim) via
--   SET LOCAL ariadne.tenant = '<tenant uuid>';
-- inside the request transaction. Every tenant-scoped table then self-filters, so a query
-- bug cannot leak rows across tenants. App-level project ACL checks still run on top.
--
-- The application connects as a NON-superuser, non-BYPASSRLS role (ariadne_app). Superuser
-- and the migration role bypass RLS, which is why migrations/back-office run as a different
-- role than request handling.

BEGIN;

-- Helper: current tenant from the GUC, NULL-safe.
CREATE FUNCTION ariadne_current_tenant() RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('ariadne.tenant', true), '')::uuid
$$;

-- Apply the same policy shape to every tenant-scoped table.
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'app_user','project','session','folder_binding',
        'event','summary','memory','artifact','job'
    ] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY;', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY;', t);
        EXECUTE format($f$
            CREATE POLICY tenant_isolation ON %I
            USING (tenant_id = ariadne_current_tenant())
            WITH CHECK (tenant_id = ariadne_current_tenant());
        $f$, t);
    END LOOP;
END $$;

-- Child tables without their own tenant_id inherit isolation via their parent FK +
-- app-level checks: project_acl (via project), state_doc / state_doc_history / checkpoint
-- (via project), stage_cursor (via project). They are only reached through a project the
-- policy above already gated, so no separate policy is required in v1. Revisit if any of
-- these become directly queryable by tenant.

COMMIT;
