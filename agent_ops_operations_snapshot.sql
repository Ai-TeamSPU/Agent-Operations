CREATE OR REPLACE FUNCTION public.agent_ops_operations_snapshot(p_workspace_slug text DEFAULT 'agent-factory'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare w agent_ops.workspaces%rowtype; n bigint; result jsonb;
begin
 select * into w from agent_ops.workspaces where slug=p_workspace_slug;
 if not found then raise exception 'Workspace not found or access denied' using errcode='42501'; end if;
 select count(*) into n from agent_ops.operation_runs where workspace_id=w.id and environment='production';
 if n>20000 then raise exception 'Snapshot exceeds 20,000 runs; use paginated reporting; partial metrics are not returned' using errcode='54000'; end if;
 with confirmed_skills as materialized (
  select distinct on(code) * from agent_ops.skills where workspace_id=w.id and status='active' and implementation_verified_at is not null and nullif(trim(implementation_evidence),'') is not null order by code,implementation_verified_at desc,version desc
 ), confirmed_agents as materialized (
  select * from agent_ops.agents where workspace_id=w.id and lifecycle='active' and implementation_verified_at is not null and nullif(trim(implementation_evidence),'') is not null
 ), confirmed_mappings as materialized (
  select m.* from agent_ops.agent_skills m join confirmed_agents a on a.code=m.agent_code join confirmed_skills s on s.code=m.skill_code and s.version=m.skill_version where m.workspace_id=w.id and m.mapping_status='verified'
 )
 select jsonb_build_object('schemaVersion',3,'generatedAt',statement_timestamp(),
 'workspace',jsonb_build_object('id',w.id,'slug',w.slug,'name',w.name,'collectionStatus',w.collection_status),
 'memberRole',(select role from agent_ops.members where workspace_id=w.id and user_id=(select auth.uid()) and active),
 'scope',jsonb_build_object('environment','production','sources',jsonb_build_array('runtime','manual','import'),'table','agent_ops.operation_runs','rows',n,'truncated',false,'registryPolicy','admin_attested_implementation_only'),
 'coverage',jsonb_build_object('legacyEventRows',(select count(*) from agent_ops.execution_events where workspace_id=w.id and environment='production' and source_kind='runtime'),'runtimeRuns',(select count(*) from agent_ops.operation_runs where workspace_id=w.id and environment='production' and source_kind='runtime'),'manualRuns',(select count(*) from agent_ops.operation_runs where workspace_id=w.id and environment='production' and source_kind='manual'),'importedRuns',(select count(*) from agent_ops.operation_runs where workspace_id=w.id and environment='production' and source_kind='import'),'excludedUnverifiedAgents',(select count(*) from agent_ops.agents where workspace_id=w.id)-(select count(*) from confirmed_agents),'excludedUnverifiedSkills',(select count(*) from agent_ops.skills where workspace_id=w.id)-(select count(*) from confirmed_skills)),
 'registry',jsonb_build_object('schemaVersion',1,'agents',(select coalesce(jsonb_agg(jsonb_build_object('id',a.code,'name',a.name,'shortName',coalesce(a.short_name,a.name),'role',coalesce(a.role_description,''),'group',a.group_name,'provenance',a.provenance,'lifecycle',a.lifecycle,'runtimeStatus',a.runtime_status,'version',a.version,'sourceNote',a.source_note,'sourceUri',a.source_uri,'confirmedCreated',true,'implementationEvidence',a.implementation_evidence,'verifiedAt',a.implementation_verified_at,'isOrchestrator',a.is_orchestrator is true,'mappingStatus','verified',
 'skillIds',coalesce((select jsonb_agg(distinct m.skill_code) from confirmed_mappings m where m.agent_code=a.code and m.is_assigned),'[]'::jsonb),
 'requiredSkillIds',coalesce((select jsonb_agg(distinct m.skill_code) from confirmed_mappings m where m.agent_code=a.code and m.is_required),'[]'::jsonb)) order by a.code),'[]'::jsonb) from confirmed_agents a),
 'skills',(select coalesce(jsonb_agg(jsonb_build_object('id',s.code,'name',s.name,'description',coalesce(s.description,''),'status',s.status,'version',s.version,'sourceNote',s.source_note,'confirmedCreated',true,'implementationEvidence',s.implementation_evidence,'verifiedAt',s.implementation_verified_at) order by s.code),'[]'::jsonb) from confirmed_skills s)),
 'runs',(select coalesce(jsonb_agg(jsonb_build_object('id',r.run_id,'data',r.payload||jsonb_build_object('_source',jsonb_build_object('id',r.source_id,'kind',r.source_kind,'name',case r.source_kind when 'runtime' then 'Runtime · วัดจากระบบ' when 'manual' then 'Manual · บันทึกโดยคน' else 'Import · ข้อมูลนำเข้า' end,'createdAt',r.received_at))) order by r.received_at,r.run_id),'[]'::jsonb) from agent_ops.operation_runs r where r.workspace_id=w.id and r.environment='production')) into result;
 return result;
end $function$

