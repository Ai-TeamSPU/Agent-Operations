CREATE OR REPLACE FUNCTION public.agent_ops_claim_chat(p_turn_id uuid, p_user_id uuid, p_ai_configured boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare t agent_ops.chat_turns%rowtype; th agent_ops.chat_threads%rowtype; a agent_ops.agents%rowtype; cfg agent_ops.runtime_settings%rowtype; refs jsonb; builtin boolean; stamp timestamptz:=clock_timestamp(); contract jsonb;
begin
select * into t from agent_ops.chat_turns where id=p_turn_id and user_id=p_user_id for update;
if not found or not exists(select 1 from agent_ops.members where workspace_id=t.workspace_id and user_id=p_user_id and active and role in('editor','reviewer','admin')) then raise exception 'Turn access denied' using errcode='42501'; end if;
if t.status='running' and t.started_at<stamp-interval '3 minutes' then
perform public.agent_ops_finish_chat(t.id,p_user_id,null,'WORKER_TIMEOUT',null,extract(epoch from(stamp-t.started_at))*1000,null,null);
return jsonb_build_object('status','failed','id',t.id,'errorCode','WORKER_TIMEOUT'); end if;
if t.status<>'queued' then return jsonb_build_object('status',t.status,'id',t.id,'claimed',false); end if;
select * into th from agent_ops.chat_threads where workspace_id=t.workspace_id and id=t.thread_id;
select * into a from agent_ops.agents where workspace_id=t.workspace_id and code=th.agent_code;
select * into cfg from agent_ops.runtime_settings where workspace_id=t.workspace_id;
select jsonb_build_object('key',c.contract_key,'version',c.version,'contractMd',c.contract_md,'config',c.config)
into contract from agent_ops.runtime_contracts c where c.workspace_id=t.workspace_id and c.contract_key='run-log' and c.active order by c.created_at desc limit 1;
if a.lifecycle='deprecated' or a.runtime_status='disabled' or not exists(select 1 from agent_ops.workspaces where id=t.workspace_id and collection_status<>'paused') then
update agent_ops.chat_turns set status='blocked',error_code='AGENT_DISABLED',completed_at=stamp where workspace_id=t.workspace_id and id=t.id;
return jsonb_build_object('status','blocked','errorCode','AGENT_DISABLED'); end if;
builtin:=lower(btrim(t.user_content)) in('/status','/skills');
if not builtin and (not coalesce(p_ai_configured,false) or not cfg.ai_enabled) then
update agent_ops.chat_turns set status='blocked',error_code=case when not coalesce(p_ai_configured,false) then 'AI_NOT_CONFIGURED' else 'AI_NOT_ENABLED' end,completed_at=stamp where workspace_id=t.workspace_id and id=t.id;
return jsonb_build_object('status','blocked','errorCode',case when not coalesce(p_ai_configured,false) then 'AI_NOT_CONFIGURED' else 'AI_NOT_ENABLED' end); end if;
select coalesce(jsonb_agg(to_jsonb(k)),'[]'::jsonb) into refs from(select q.knowledge_id,q.version,q.title,left(q.content_md,2000) as content_md from(select distinct on(k.knowledge_id) k.* from agent_ops.knowledge_versions k join agent_ops.source_registry s on s.workspace_id=k.workspace_id and s.id=k.source_id where k.workspace_id=t.workspace_id and k.status='approved' and k.pii_status in('clean','redacted') and s.enabled and s.allowed_for_learning order by k.knowledge_id,k.version desc)q order by q.reviewed_at desc limit 6)k;
update agent_ops.chat_turns set status='running',started_at=stamp,execution_mode=case when builtin then 'database_command' else 'role_assistant' end,context_refs=(select coalesce(jsonb_agg(x-'content_md'),'[]'::jsonb) from jsonb_array_elements(refs)x) where workspace_id=t.workspace_id and id=t.id;
insert into agent_ops.execution_events(workspace_id,producer,event_key,run_id,agent_code,agent_version,event_type,environment,occurred_at) values(t.workspace_id,'agent-ops-chat',t.id::text||':run.start',t.run_id,a.code,'chat-runtime-v1','run.started','production',stamp);
insert into agent_ops.execution_events(workspace_id,producer,event_key,run_id,span_id,agent_code,agent_version,skill_code,skill_version,step_name,event_type,environment,occurred_at) values(t.workspace_id,'agent-ops-chat',t.id::text||':skill.start',t.run_id,t.span_id,a.code,'chat-runtime-v1','chat-response','1.0.0','chat-response','skill.started','production',stamp);
return jsonb_build_object(
 'claimed',true,'status','running','id',t.id,'runId',t.run_id,
 'workspaceSlug',(select slug from agent_ops.workspaces where id=t.workspace_id),
 'message',t.user_content,
 'mode',case when builtin then 'database_command' else 'role_assistant' end,
 'agent',jsonb_build_object(
   'code',a.code,'name',a.name,'role',a.role_description,'provenance',a.provenance,
   'dnaMd',a.agent_dna_md,'requiresRunLog',a.requires_run_log,'isOrchestrator',a.is_orchestrator
 ),
 'loggingContract',contract,
 'knowledge',refs,
 'history',(select coalesce(jsonb_agg(to_jsonb(h) order by created_at),'[]'::jsonb) from(select left(user_content,4000) as user_content,left(assistant_content,6000) as assistant_content,created_at from agent_ops.chat_turns where workspace_id=t.workspace_id and thread_id=t.thread_id and user_id=p_user_id and status='succeeded' order by created_at desc limit 4)h)
);
end $function$

