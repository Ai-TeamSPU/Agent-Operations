CREATE OR REPLACE FUNCTION public.agent_ops_orchestrator_gate(p_workspace_slug text, p_expected_agent_codes text[], p_child_run_ids text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare wid uuid; missing_agents text[]; missing_runs text[]; mismatched jsonb;
begin
select id into wid from agent_ops.workspaces where slug=p_workspace_slug;
if wid is null or not exists(select 1 from agent_ops.members where workspace_id=wid and user_id=(select auth.uid()) and active) then
  raise exception 'Workspace access required' using errcode='42501';
end if;
if p_expected_agent_codes is null or p_child_run_ids is null or cardinality(p_expected_agent_codes)<>cardinality(p_child_run_ids) then
  raise exception 'Expected agents and run IDs must be paired' using errcode='22023';
end if;
select coalesce(array_agg(agent),'{}') into missing_agents
from unnest(p_expected_agent_codes,p_child_run_ids) as x(agent,runid)
where runid is null or btrim(runid)='';
select coalesce(array_agg(runid),'{}') into missing_runs
from unnest(p_expected_agent_codes,p_child_run_ids) as x(agent,runid)
where runid is not null and btrim(runid)<>'' and not exists(
  select 1 from agent_ops.operation_runs r where r.workspace_id=wid and r.environment='production' and r.run_id=runid
);
select coalesce(jsonb_agg(jsonb_build_object('agentId',agent,'runId',runid)),'[]'::jsonb) into mismatched
from unnest(p_expected_agent_codes,p_child_run_ids) as x(agent,runid)
where runid is not null and btrim(runid)<>'' and exists(
  select 1 from agent_ops.operation_runs r where r.workspace_id=wid and r.environment='production' and r.run_id=runid
) and not exists(
  select 1 from agent_ops.operation_runs r where r.workspace_id=wid and r.environment='production' and r.run_id=runid and r.payload->>'agentId'=agent
);
return jsonb_build_object(
 'complete',cardinality(missing_agents)=0 and cardinality(missing_runs)=0 and jsonb_array_length(mismatched)=0,
 'missingAgentRunIds',to_jsonb(missing_agents),
 'unloggedRunIds',to_jsonb(missing_runs),
 'mismatchedAgentRunPairs',mismatched
);
end $function$

