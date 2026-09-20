-- Read-only inspection. Creates no Agent, Skill, member, or execution record.
select statement_timestamp() as verified_at,
 (select count(*) from agent_ops.operation_runs) as operation_run_rows,
 (select count(*) from agent_ops.execution_events) as execution_event_rows,
 (select count(*) from agent_ops.members where active) as active_workspace_members,
 jsonb_array_length(public.agent_ops_operations_snapshot('agent-factory')->'registry'->'agents') as confirmed_agents_in_dashboard,
 jsonb_array_length(public.agent_ops_operations_snapshot('agent-factory')->'registry'->'skills') as confirmed_skills_in_dashboard;
select n.nspname,p.proname,p.prosecdef as security_definer,
 has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute,
 has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute,
 p.proconfig
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in
 ('agent_ops_operations_snapshot','agent_ops_operations_write','agent_ops_operations_register');
-- Inspect the deployed source of the API functions; do not rerun migrations blindly.
select p.proname,pg_get_functiondef(p.oid) as definition
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in
 ('agent_ops_operations_snapshot','agent_ops_operations_write','agent_ops_operations_register');
