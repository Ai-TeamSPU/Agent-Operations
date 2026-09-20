-- Run once in this project's Supabase SQL Editor as its authorized administrator:
-- project: doxunxbgqmybyckczucg / workspace: agent-factory
-- This grants ONLY datateam.gpt@spu.ac.th admin access to Agent Operations.
-- No password, MFA, Auth URL, HR/DL role, RLS policy, Agent or RUN_LOG is changed.
-- Existing roles are not overwritten; the operation is atomic and repeat-safe.
BEGIN;
SET LOCAL statement_timeout = '8s';
SET LOCAL lock_timeout = '3s';
DO $setup$
DECLARE
    target_user uuid;
    target_workspace uuid;
    existing_role text;
    existing_active boolean;
BEGIN
    SELECT u.id INTO STRICT target_user
    FROM auth.users AS u
    WHERE lower(u.email) = 'datateam.gpt@spu.ac.th'
      AND u.id = '4871d051-9f13-45a7-8927-e3e10686c2cf'::uuid
      AND u.email_confirmed_at IS NOT NULL
      AND u.deleted_at IS NULL
      AND (u.banned_until IS NULL OR u.banned_until <= statement_timestamp());

    SELECT w.id INTO STRICT target_workspace
    FROM agent_ops.workspaces AS w
    WHERE w.slug = 'agent-factory'
      AND w.id = 'b3985efb-cedd-4664-91c5-698bfad95bcf'::uuid;

    INSERT INTO agent_ops.members(workspace_id, user_id, role, active)
    VALUES (target_workspace, target_user, 'admin', true)
    ON CONFLICT (workspace_id, user_id) DO NOTHING;

    SELECT m.role, m.active INTO STRICT existing_role, existing_active
    FROM agent_ops.members AS m
    WHERE m.workspace_id = target_workspace AND m.user_id = target_user;

    IF existing_role <> 'admin' OR existing_active IS NOT TRUE THEN
        RAISE EXCEPTION 'An existing membership has a different role or is inactive. No override performed; review it as the project administrator.';
    END IF;
END;
$setup$;

-- Receipt: returns the specific account, workspace and resulting permission only.
SELECT u.email, w.slug AS workspace, m.role, m.active
FROM agent_ops.members AS m
JOIN agent_ops.workspaces AS w ON w.id = m.workspace_id
JOIN auth.users AS u ON u.id = m.user_id
WHERE w.id = 'b3985efb-cedd-4664-91c5-698bfad95bcf'::uuid
  AND u.id = '4871d051-9f13-45a7-8927-e3e10686c2cf'::uuid;
COMMIT;
