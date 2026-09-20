-- Same no-identity access checks executed against the live database.
-- No account or business row is created. Statements are rolled back.
begin;
set local role authenticated;
do $$ begin
 if (select auth.uid()) is not null then raise exception 'Test requires no user identity'; end if;
 if exists(select 1 from agent_ops.agents) or exists(select 1 from agent_ops.skills) or exists(select 1 from agent_ops.operation_runs) then raise exception 'RLS exposed rows without identity'; end if;
 begin perform public.agent_ops_operations_snapshot('agent-factory'); raise exception 'Snapshot unexpectedly allowed'; exception when insufficient_privilege then null; end;
 begin perform public.agent_ops_operations_write('agent-factory','[]'::jsonb,'empty-access-check','import','production'); raise exception 'Write unexpectedly allowed'; exception when insufficient_privilege then null; end;
 begin perform public.agent_ops_operations_register('agent-factory','{"agents":[],"skills":[]}'::jsonb); raise exception 'Registry write unexpectedly allowed'; exception when insufficient_privilege then null; end;
end $$;
rollback;
begin;
set local role anon;
do $$ begin
 begin perform public.agent_ops_operations_snapshot('agent-factory'); raise exception 'Anonymous snapshot unexpectedly allowed'; exception when insufficient_privilege then null; end;
end $$;
rollback;
select 'passed' as no_identity_and_anonymous_access_checks,
 (select count(*) from agent_ops.operation_runs) as operation_run_rows_after_checks;
