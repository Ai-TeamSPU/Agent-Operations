-- Agent Operations production runtime hardening. Existing project baseline required.
-- Scope is agent_ops and public.agent_ops_* only. No HR / DL tables or membership changes.
-- No seed runs or fabricated metrics. RUN_LOG 1.0.0 payload remains unchanged.
begin;

create table agent_ops.orchestrations (
 workspace_id uuid not null references agent_ops.workspaces(id),
 id uuid not null default gen_random_uuid(),
 user_id uuid not null default auth.uid() references auth.users(id),
 request_id uuid not null,
 orchestrator_code text not null,
 agent_codes text[] not null check(cardinality(agent_codes) between 2 and 3),
 user_content text not null check(length(btrim(user_content)) between 1 and 8000),
 created_at timestamptz not null default now(),
 primary key(workspace_id,id),
 unique(workspace_id,user_id,request_id),
 foreign key(workspace_id,orchestrator_code) references agent_ops.agents(workspace_id,code)
);
alter table agent_ops.orchestrations enable row level security;
create policy orchestration_owner_read on agent_ops.orchestrations for select to authenticated
 using(user_id=(select auth.uid()) and exists(select 1 from agent_ops.members m where m.workspace_id=orchestrations.workspace_id and m.user_id=(select auth.uid()) and m.active));
create policy orchestration_owner_insert on agent_ops.orchestrations for insert to authenticated
 with check(user_id=(select auth.uid()) and exists(select 1 from agent_ops.members m where m.workspace_id=orchestrations.workspace_id and m.user_id=(select auth.uid()) and m.active and m.role in('editor','reviewer','admin')));
revoke all on agent_ops.orchestrations from public,anon,authenticated;
grant select on agent_ops.orchestrations to authenticated,service_role;
grant insert(workspace_id,request_id,orchestrator_code,agent_codes,user_content) on agent_ops.orchestrations to authenticated;

alter table agent_ops.chat_turns
 add column orchestration_id uuid,
 add column parent_turn_id uuid,
 add constraint chat_turns_orchestration_fk foreign key(workspace_id,orchestration_id) references agent_ops.orchestrations(workspace_id,id),
 add constraint chat_turns_parent_fk foreign key(workspace_id,parent_turn_id) references agent_ops.chat_turns(workspace_id,id),
 add constraint chat_turns_parent_requires_orchestration check(parent_turn_id is null or orchestration_id is not null);
create unique index chat_orchestration_root_uq on agent_ops.chat_turns(workspace_id,orchestration_id) where orchestration_id is not null and parent_turn_id is null;
create index chat_orchestration_idx on agent_ops.chat_turns(workspace_id,orchestration_id,parent_turn_id);
grant insert(orchestration_id,parent_turn_id) on agent_ops.chat_turns to authenticated;

alter table agent_ops.operation_runs add column source_turn_id uuid,add column orchestration_id uuid,add column parent_run_id text,
 add constraint operation_runs_turn_fk foreign key(workspace_id,source_turn_id) references agent_ops.chat_turns(workspace_id,id),
 add constraint operation_runs_orchestration_fk foreign key(workspace_id,orchestration_id) references agent_ops.orchestrations(workspace_id,id);
create unique index operation_runs_source_turn_uq on agent_ops.operation_runs(workspace_id,source_turn_id) where source_turn_id is not null;
create index operation_runs_orchestration_idx on agent_ops.operation_runs(workspace_id,orchestration_id);

create or replace function agent_ops.turn_run_payload(p_turn agent_ops.chat_turns) returns jsonb
 language sql stable set search_path='' as $$
 select jsonb_build_object(
 'runId',p_turn.run_id::text,'agentId',th.agent_code,
 'startedAt',to_char(coalesce(p_turn.started_at,p_turn.created_at) at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
 'status',case when p_turn.status='succeeded' then 'success' else 'failed' end,
 'trigger',case when p_turn.parent_turn_id is null then 'user' else 'agent' end,
 'parentAgentId',pth.agent_code,
 'steps',jsonb_build_array(jsonb_build_object('stage',case when p_turn.error_code='QUEUE_TIMEOUT' then 'intake' when p_turn.error_code in('AGENT_DISABLED','AGENT_DNA_INVALID','LOGGING_CONTRACT_INVALID','AI_NOT_CONFIGURED','AI_NOT_ENABLED','CHILD_RUN_FAILED','ORCHESTRATOR_GATE_FAILED') then 'validation' else 'execution' end,'skillId','chat-response',
 'durationSec',round((p_turn.duration_ms/1000.0)::numeric,3),
 'waitSec',round(greatest(0,extract(epoch from(coalesce(p_turn.started_at,p_turn.created_at)-p_turn.created_at)))::numeric,3),
 'status',case when p_turn.status='succeeded' then 'ok' else 'fail' end,'retries',0)))
 from agent_ops.chat_threads th
 left join agent_ops.chat_turns pt on pt.workspace_id=p_turn.workspace_id and pt.id=p_turn.parent_turn_id
 left join agent_ops.chat_threads pth on pth.workspace_id=pt.workspace_id and pth.id=pt.thread_id
 where th.workspace_id=p_turn.workspace_id and th.id=p_turn.thread_id
$$;

create or replace function agent_ops.chat_receipt(p_workspace_id uuid,p_turn_id uuid) returns jsonb
 language sql stable set search_path='' as $$
 select jsonb_build_object('id',t.id,'threadId',t.thread_id,'agentId',th.agent_code,'runId',t.run_id,
 'status',t.status,'answer',t.assistant_content,'errorCode',t.error_code,'orchestrationId',t.orchestration_id,
 'parentRunId',pt.run_id,'logging',case when r.run_id is not null then 'logged' else 'logging_failed' end)
 from agent_ops.chat_turns t join agent_ops.chat_threads th on th.workspace_id=t.workspace_id and th.id=t.thread_id
 left join agent_ops.chat_turns pt on pt.workspace_id=t.workspace_id and pt.id=t.parent_turn_id
 left join agent_ops.operation_runs r on r.workspace_id=t.workspace_id and r.environment='production' and r.run_id=t.run_id::text
 and r.source_kind='runtime' and r.source_id='agent-ops-chat' and r.source_turn_id=t.id and r.created_by=t.user_id
 and r.orchestration_id is not distinct from t.orchestration_id and r.parent_run_id is not distinct from pt.run_id::text
 and r.payload=agent_ops.turn_run_payload(t) and t.status in('succeeded','failed')
 where t.workspace_id=p_workspace_id and t.id=p_turn_id
$$;

create or replace function agent_ops.orchestration_gate(p_workspace_id uuid,p_orchestration_id uuid) returns jsonb
 language plpgsql stable set search_path='' as $$
 declare o agent_ops.orchestrations%rowtype; children jsonb; expected int; verified int; actual int; unique_agents int; rootid uuid;
 begin
 select * into o from agent_ops.orchestrations where workspace_id=p_workspace_id and id=p_orchestration_id;
 if not found then return jsonb_build_object('complete',false,'reason','ORCHESTRATION_NOT_FOUND','children','[]'::jsonb); end if;
 select id into rootid from agent_ops.chat_turns where workspace_id=o.workspace_id and orchestration_id=o.id and parent_turn_id is null and user_id=o.user_id;
 expected:=cardinality(o.agent_codes);
 select count(*),count(distinct th.agent_code),count(*) filter(where th.agent_code=any(o.agent_codes) and t.status='succeeded' and agent_ops.chat_receipt(t.workspace_id,t.id)->>'logging'='logged'),
 coalesce(jsonb_agg(agent_ops.chat_receipt(t.workspace_id,t.id) order by th.agent_code),'[]'::jsonb)
 into actual,unique_agents,verified,children from agent_ops.chat_turns t join agent_ops.chat_threads th on th.workspace_id=t.workspace_id and th.id=t.thread_id
 where t.workspace_id=o.workspace_id and t.orchestration_id=o.id and t.parent_turn_id=rootid and t.user_id=o.user_id;
 return jsonb_build_object('complete',rootid is not null and expected between 2 and 3 and actual=expected and unique_agents=expected and (select count(distinct x) from unnest(o.agent_codes)x)=expected and verified=expected,
 'orchestrationId',o.id,'parentTurnId',rootid,'expectedCount',expected,'verifiedCount',verified,'children',children);
 end $$;

create or replace function public.agent_ops_verify_chat(p_turn_id uuid,p_user_id uuid) returns jsonb
 language plpgsql stable set search_path='' as $$
 declare t agent_ops.chat_turns%rowtype; result jsonb; gate jsonb;
 begin
 if current_user not in('postgres','service_role') then raise exception 'Runtime service required' using errcode='42501'; end if;
 select * into t from agent_ops.chat_turns where id=p_turn_id and user_id=p_user_id;
 if not found or not exists(select 1 from agent_ops.members where workspace_id=t.workspace_id and user_id=p_user_id and active and role in('editor','reviewer','admin')) then raise exception 'Turn unavailable' using errcode='42501'; end if;
 result:=agent_ops.chat_receipt(t.workspace_id,t.id);
 if t.orchestration_id is not null and t.parent_turn_id is null then
 gate:=agent_ops.orchestration_gate(t.workspace_id,t.orchestration_id);
 result:=result||jsonb_build_object('children',gate->'children','gate',gate);
 end if;
 return result;
 end $$;

create or replace function public.agent_ops_finish_chat(p_turn_id uuid,p_user_id uuid,p_answer text,p_error_code text,p_model text,p_duration_ms numeric,p_input_tokens bigint default null,p_output_tokens bigint default null)
 returns jsonb language plpgsql set search_path='' as $$
 declare t agent_ops.chat_turns%rowtype; a text; done timestamptz:=clock_timestamp(); ev text; payload jsonb; err text:=p_error_code; parentrun text; receipt jsonb; gate jsonb;
 begin
 if current_user not in('postgres','service_role') then raise exception 'Runtime service required' using errcode='42501'; end if;
 select * into t from agent_ops.chat_turns where id=p_turn_id and user_id=p_user_id for update;
 if not found then raise exception 'Turn unavailable' using errcode='42501'; end if;
 if t.status<>'running' then
  if t.status in('succeeded','failed') and (t.assistant_content is distinct from case when err is null then p_answer else null end or t.error_code is distinct from err or t.model is distinct from left(p_model,200) or t.duration_ms is distinct from p_duration_ms or t.input_tokens is distinct from p_input_tokens or t.output_tokens is distinct from p_output_tokens) then
   raise exception 'Completion replay has different content' using errcode='23505';
  end if;
  return public.agent_ops_verify_chat(t.id,p_user_id);
 end if;
 if err is null and t.orchestration_id is not null and t.parent_turn_id is null and not coalesce((agent_ops.orchestration_gate(t.workspace_id,t.orchestration_id)->>'complete')::boolean,false) then err:='ORCHESTRATOR_GATE_FAILED'; end if;
 if err is null and (p_answer is null or length(btrim(p_answer)) not between 1 and 60000) then raise exception 'Invalid result length' using errcode='22023'; end if;
 if err is not null and err !~ '^[A-Z0-9_]{1,80}$' then raise exception 'Invalid error code' using errcode='22023'; end if;
 if p_duration_ms is null or p_duration_ms<0 or p_duration_ms>31536000000 or coalesce(p_input_tokens,0)<0 or coalesce(p_output_tokens,0)<0 then raise exception 'Invalid metrics' using errcode='22023'; end if;
 select agent_code into a from agent_ops.chat_threads where workspace_id=t.workspace_id and id=t.thread_id;
 select run_id::text into parentrun from agent_ops.chat_turns where workspace_id=t.workspace_id and id=t.parent_turn_id;
 ev:=case when err is null then 'succeeded' else 'failed' end;
 update agent_ops.chat_turns set status=ev,assistant_content=case when err is null then p_answer else null end,error_code=err,model=left(p_model,200),duration_ms=p_duration_ms,input_tokens=p_input_tokens,output_tokens=p_output_tokens,completed_at=done where workspace_id=t.workspace_id and id=t.id returning * into t;
 insert into agent_ops.execution_events(workspace_id,producer,event_key,run_id,span_id,agent_code,agent_version,skill_code,skill_version,step_name,event_type,environment,occurred_at,duration_ms,input_tokens,output_tokens,error_code)
 values(t.workspace_id,'agent-ops-chat',t.id::text||':skill.end',t.run_id,t.span_id,a,'chat-runtime-v2','chat-response','1.0.0','chat-response','skill.'||ev,'production',done,p_duration_ms,p_input_tokens,p_output_tokens,err);
 insert into agent_ops.execution_events(workspace_id,producer,event_key,run_id,agent_code,agent_version,event_type,environment,occurred_at,duration_ms,input_tokens,output_tokens,error_code)
 values(t.workspace_id,'agent-ops-chat',t.id::text||':run.end',t.run_id,a,'chat-runtime-v2','run.'||ev,'production',done,p_duration_ms,p_input_tokens,p_output_tokens,err);
 payload:=agent_ops.turn_run_payload(t);
 insert into agent_ops.operation_runs(workspace_id,run_id,environment,source_kind,source_id,payload,created_by,source_turn_id,orchestration_id,parent_run_id)
 values(t.workspace_id,t.run_id::text,'production','runtime','agent-ops-chat',payload,p_user_id,t.id,t.orchestration_id,parentrun)
 on conflict(workspace_id,environment,run_id) do nothing;
 receipt:=agent_ops.chat_receipt(t.workspace_id,t.id);
 if t.orchestration_id is not null and t.parent_turn_id is null then gate:=agent_ops.orchestration_gate(t.workspace_id,t.orchestration_id); receipt:=receipt||jsonb_build_object('children',gate->'children','gate',gate); end if;
 if not exists(select 1 from agent_ops.members where workspace_id=t.workspace_id and user_id=p_user_id and active and role in('editor','reviewer','admin')) then receipt:=receipt-'answer'; end if;
 if receipt->>'logging'<>'logged' then raise exception 'runId source/payload collision; completion rolled back' using errcode='23505'; end if;
 return receipt;
 end $$;

create or replace function public.agent_ops_claim_chat(p_turn_id uuid,p_user_id uuid,p_ai_configured boolean) returns jsonb
 language plpgsql set search_path='' as $$
 declare t agent_ops.chat_turns%rowtype; th agent_ops.chat_threads%rowtype; a agent_ops.agents%rowtype; cfg agent_ops.runtime_settings%rowtype; refs jsonb; builtin boolean; stamp timestamptz:=clock_timestamp(); contract jsonb; err text; gate jsonb; kids jsonb;
 begin
 if current_user not in('postgres','service_role') then raise exception 'Runtime service required' using errcode='42501'; end if;
 select * into t from agent_ops.chat_turns where id=p_turn_id and user_id=p_user_id for update;
 if not found or not exists(select 1 from agent_ops.members where workspace_id=t.workspace_id and user_id=p_user_id and active and role in('editor','reviewer','admin')) then raise exception 'Turn access denied' using errcode='42501'; end if;
 if t.status='running' and t.started_at<stamp-interval '3 minutes' then return public.agent_ops_finish_chat(t.id,p_user_id,null,'WORKER_TIMEOUT',null,extract(epoch from(stamp-t.started_at))*1000,null,null)||jsonb_build_object('claimed',false); end if;
 if t.status<>'queued' then return public.agent_ops_verify_chat(t.id,p_user_id)||jsonb_build_object('claimed',false); end if;
 if not exists(select 1 from agent_ops.members where workspace_id=t.workspace_id and user_id=p_user_id and active and role in('editor','reviewer','admin')) then raise exception 'Turn access denied' using errcode='42501'; end if;
 select * into th from agent_ops.chat_threads where workspace_id=t.workspace_id and id=t.thread_id;
 select * into a from agent_ops.agents where workspace_id=t.workspace_id and code=th.agent_code;
 select * into cfg from agent_ops.runtime_settings where workspace_id=t.workspace_id;
 if t.orchestration_id is not null and t.parent_turn_id is null then
  gate:=agent_ops.orchestration_gate(t.workspace_id,t.orchestration_id);
  select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'agentId',ct.agent_code,'runId',c.run_id) order by ct.agent_code),'[]'::jsonb) into kids
  from agent_ops.chat_turns c join agent_ops.chat_threads ct on ct.workspace_id=c.workspace_id and ct.id=c.thread_id where c.workspace_id=t.workspace_id and c.orchestration_id=t.orchestration_id and c.parent_turn_id=t.id;
  if exists(select 1 from agent_ops.chat_turns c where c.workspace_id=t.workspace_id and c.orchestration_id=t.orchestration_id and c.parent_turn_id=t.id and c.status in('queued','running')) then
   return jsonb_build_object('claimed',false,'id',t.id,'status','waiting_for_children','agentId',a.code,'runId',t.run_id,'orchestrationId',t.orchestration_id,'childTurns',kids,'gate',gate);
  end if;
  if not coalesce((gate->>'complete')::boolean,false) then err:='CHILD_RUN_FAILED'; end if;
 end if;
 select jsonb_build_object('key',c.contract_key,'version',c.version,'contractMd',c.contract_md,'config',c.config) into contract
 from agent_ops.runtime_contracts c where c.workspace_id=t.workspace_id and c.contract_key='run-log' and c.active and c.version=a.logging_contract_version order by c.created_at desc limit 1;
 builtin:=left(btrim(t.user_content),1)='/' and t.orchestration_id is null;
 err:=coalesce(err,case
 when a.code is null or a.lifecycle='deprecated' or a.runtime_status='disabled' or not exists(select 1 from agent_ops.workspaces where id=t.workspace_id and collection_status<>'paused') then 'AGENT_DISABLED'
 when a.requires_run_log is distinct from true or nullif(btrim(a.agent_dna_md),'') is null or position('runId' in a.agent_dna_md)=0 or position('RUN_LOG' in a.agent_dna_md)=0 then 'AGENT_DNA_INVALID'
 when contract is null or contract->>'version' is distinct from '1.0.0' or contract#>>'{config,sourceKind}' is distinct from 'runtime' or contract#>>'{config,environment}' is distinct from 'production' or contract#>>'{config,noSyntheticData}' is distinct from 'true' or contract#>>'{config,noPII}' is distinct from 'true' or contract#>>'{config,workspace}' is distinct from (select slug from agent_ops.workspaces where id=t.workspace_id) or nullif(btrim(contract->>'contractMd'),'') is null or not coalesce((contract#>'{config,requiredReturnFields}') ?& array['agentId','runId','status','logging'],false) then 'LOGGING_CONTRACT_INVALID'
 when not builtin and not coalesce(p_ai_configured,false) then 'AI_NOT_CONFIGURED'
 when not builtin and not coalesce(cfg.ai_enabled,false) then 'AI_NOT_ENABLED' end);
 select coalesce(jsonb_agg(to_jsonb(k)),'[]'::jsonb) into refs from(select q.knowledge_id,q.version,q.title,left(q.content_md,2000) as content_md from(select distinct on(k.knowledge_id) k.* from agent_ops.knowledge_versions k join agent_ops.source_registry s on s.workspace_id=k.workspace_id and s.id=k.source_id where k.workspace_id=t.workspace_id and k.status='approved' and k.pii_status in('clean','redacted') and s.enabled and s.allowed_for_learning order by k.knowledge_id,k.version desc)q order by q.reviewed_at desc limit 6)k;
 update agent_ops.chat_turns set status='running',started_at=stamp,execution_mode=case when builtin then 'database_command' else 'role_assistant' end,context_refs=(select coalesce(jsonb_agg(x-'content_md'),'[]'::jsonb) from jsonb_array_elements(refs)x) where workspace_id=t.workspace_id and id=t.id;
 insert into agent_ops.execution_events(workspace_id,producer,event_key,run_id,agent_code,agent_version,event_type,environment,occurred_at)
 values(t.workspace_id,'agent-ops-chat',t.id::text||':run.start',t.run_id,a.code,'chat-runtime-v2','run.started','production',stamp);
 insert into agent_ops.execution_events(workspace_id,producer,event_key,run_id,span_id,agent_code,agent_version,skill_code,skill_version,step_name,event_type,environment,occurred_at)
 values(t.workspace_id,'agent-ops-chat',t.id::text||':skill.start',t.run_id,t.span_id,a.code,'chat-runtime-v2','chat-response','1.0.0','chat-response','skill.started','production',stamp);
 if err is not null then return public.agent_ops_finish_chat(t.id,p_user_id,null,err,null,extract(epoch from(clock_timestamp()-stamp))*1000,null,null)||jsonb_build_object('claimed',false); end if;
 return jsonb_build_object('claimed',true,'status','running','id',t.id,'runId',t.run_id,'agentId',a.code,'orchestrationId',t.orchestration_id,
 'parentRunId',(select run_id from agent_ops.chat_turns where workspace_id=t.workspace_id and id=t.parent_turn_id),
 'workspaceSlug',(select slug from agent_ops.workspaces where id=t.workspace_id),'message',t.user_content,'mode',case when builtin then 'database_command' else 'role_assistant' end,
 'agent',jsonb_build_object('code',a.code,'name',a.name,'role',a.role_description,'provenance',a.provenance,'dnaMd',a.agent_dna_md,'requiresRunLog',a.requires_run_log,'isOrchestrator',a.is_orchestrator),
 'loggingContract',contract,'knowledge',refs,'childResults',coalesce(gate->'children','[]'::jsonb),'gate',gate,
 'history',(select coalesce(jsonb_agg(to_jsonb(h) order by created_at),'[]'::jsonb) from(select left(user_content,4000) as user_content,left(assistant_content,6000) as assistant_content,created_at from agent_ops.chat_turns where workspace_id=t.workspace_id and thread_id=t.thread_id and user_id=p_user_id and status='succeeded' order by created_at desc limit 4)h));
 end $$;

create or replace function agent_ops.guard_chat_insert() returns trigger language plpgsql set search_path='' as $$
 declare cfg agent_ops.runtime_settings%rowtype; o agent_ops.orchestrations%rowtype; agentcode text; parent agent_ops.chat_turns%rowtype;
 begin
 if (select auth.uid()) is null or new.user_id is distinct from (select auth.uid()) then raise exception 'Sign in to submit' using errcode='42501'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.workspace_id::text||':chat:'||new.user_id::text,0));
 select * into cfg from agent_ops.runtime_settings where workspace_id=new.workspace_id;
 if not found then raise exception 'Runtime unavailable' using errcode='42501'; end if;
 if exists(select 1 from agent_ops.chat_turns where workspace_id=new.workspace_id and user_id=new.user_id and status in('queued','running') and (new.orchestration_id is null or orchestration_id is distinct from new.orchestration_id)) then raise exception 'Finish or resolve the pending turn first' using errcode='55000'; end if;
 select agent_code into agentcode from agent_ops.chat_threads where workspace_id=new.workspace_id and id=new.thread_id and user_id=new.user_id;
 if new.orchestration_id is not null then
  select * into o from agent_ops.orchestrations where workspace_id=new.workspace_id and id=new.orchestration_id and user_id=new.user_id;
  if not found or new.user_content is distinct from o.user_content or cardinality(o.agent_codes) not between 2 and 3 or (select count(distinct x) from unnest(o.agent_codes)x)<>cardinality(o.agent_codes) or array_position(o.agent_codes,null) is not null or o.orchestrator_code=any(o.agent_codes) then raise exception 'Invalid orchestration' using errcode='22023'; end if;
  if new.parent_turn_id is null then
   if agentcode is distinct from o.orchestrator_code or not exists(select 1 from agent_ops.agents where workspace_id=new.workspace_id and code=agentcode and is_orchestrator is true and lifecycle<>'deprecated' and runtime_status<>'disabled') then raise exception 'Orchestrator required' using errcode='42501'; end if;
  else
   select * into parent from agent_ops.chat_turns where workspace_id=new.workspace_id and id=new.parent_turn_id and orchestration_id=new.orchestration_id and parent_turn_id is null and user_id=new.user_id and status='queued';
   if not found or agentcode is null or not(agentcode=any(o.agent_codes)) or exists(select 1 from agent_ops.chat_turns c join agent_ops.chat_threads th on th.workspace_id=c.workspace_id and th.id=c.thread_id where c.workspace_id=new.workspace_id and c.orchestration_id=new.orchestration_id and th.agent_code=agentcode) then raise exception 'Invalid or duplicate child' using errcode='23505'; end if;
  end if;
 end if;
 if (select count(*) from agent_ops.chat_turns where workspace_id=new.workspace_id and user_id=new.user_id and created_at>now()-interval '1 minute')>=cfg.requests_per_minute or (select count(*) from agent_ops.chat_turns where workspace_id=new.workspace_id and user_id=new.user_id and created_at>now()-interval '24 hours')>=cfg.requests_per_day then raise exception 'Chat request limit reached' using errcode='54000'; end if;
 return new;
 end $$;

create or replace function public.agent_ops_submit_orchestration(p_workspace_slug text,p_orchestrator_code text,p_agent_codes text[],p_request_id uuid,p_message text)
 returns jsonb language plpgsql set search_path='' as $$
 declare wid uuid; o agent_ops.orchestrations%rowtype; root agent_ops.chat_turns%rowtype; child agent_ops.chat_turns%rowtype; tid uuid; child_code text; children jsonb; reused boolean:=false;
 begin
 if (select auth.uid()) is null or p_request_id is null or p_message is null or length(btrim(p_message)) not between 1 and 8000 or p_agent_codes is null or cardinality(p_agent_codes) not between 2 and 3 or array_position(p_agent_codes,null) is not null or (select count(distinct x) from unnest(p_agent_codes)x)<>cardinality(p_agent_codes) or p_orchestrator_code=any(p_agent_codes) then raise exception 'A user, request ID, message and 2–3 unique child agents are required' using errcode='22023'; end if;
 select id into wid from agent_ops.workspaces where slug=p_workspace_slug and collection_status<>'paused';
 if wid is null or not exists(select 1 from agent_ops.members where workspace_id=wid and user_id=(select auth.uid()) and active and role in('editor','reviewer','admin')) then raise exception 'Editor access required' using errcode='42501'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(wid::text||':chat:'||(select auth.uid())::text,0));
 select * into o from agent_ops.orchestrations where workspace_id=wid and user_id=(select auth.uid()) and request_id=p_request_id;
 if found then
  if o.orchestrator_code is distinct from p_orchestrator_code or o.agent_codes is distinct from p_agent_codes or o.user_content is distinct from btrim(p_message) then raise exception 'Request ID reused with different content' using errcode='23505'; end if;
  reused:=true;
  select * into root from agent_ops.chat_turns where workspace_id=wid and orchestration_id=o.id and parent_turn_id is null;
  if not found then raise exception 'Incomplete orchestration submission' using errcode='55000'; end if;
 else
  if exists(select 1 from agent_ops.chat_turns where workspace_id=wid and user_id=(select auth.uid()) and request_id=p_request_id) then raise exception 'Request ID already used for chat' using errcode='23505'; end if;
  if not exists(select 1 from agent_ops.agents where workspace_id=wid and code=p_orchestrator_code and is_orchestrator is true and lifecycle<>'deprecated' and runtime_status<>'disabled') or exists(select 1 from unnest(p_agent_codes)c where not exists(select 1 from agent_ops.agents where workspace_id=wid and code=c and lifecycle<>'deprecated' and runtime_status<>'disabled')) then raise exception 'Requested agent unavailable' using errcode='42501'; end if;
  insert into agent_ops.orchestrations(workspace_id,request_id,orchestrator_code,agent_codes,user_content) values(wid,p_request_id,p_orchestrator_code,p_agent_codes,btrim(p_message)) returning * into o;
  insert into agent_ops.chat_threads(workspace_id,agent_code,title) values(wid,p_orchestrator_code,left(btrim(p_message),90)) returning id into tid;
  insert into agent_ops.chat_turns(workspace_id,thread_id,request_id,user_content,orchestration_id) values(wid,tid,p_request_id,btrim(p_message),o.id) returning * into root;
  foreach child_code in array p_agent_codes loop
   insert into agent_ops.chat_threads(workspace_id,agent_code,title) values(wid,child_code,left(btrim(p_message),90)) returning id into tid;
   insert into agent_ops.chat_turns(workspace_id,thread_id,request_id,user_content,orchestration_id,parent_turn_id) values(wid,tid,gen_random_uuid(),btrim(p_message),o.id,root.id) returning * into child;
  end loop;
 end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'threadId',c.thread_id,'agentId',ct.agent_code,'runId',c.run_id,'status',c.status) order by ct.agent_code),'[]'::jsonb) into children from agent_ops.chat_turns c join agent_ops.chat_threads ct on ct.workspace_id=c.workspace_id and ct.id=c.thread_id where c.workspace_id=wid and c.orchestration_id=o.id and c.parent_turn_id=root.id;
 return jsonb_build_object('id',root.id,'parentTurnId',root.id,'threadId',root.thread_id,'runId',root.run_id,'agentId',p_orchestrator_code,'orchestrationId',o.id,'children',children,'childTurns',children,'status',root.status,'deduplicated',reused);
 end $$;

create or replace function public.agent_ops_orchestrator_gate(p_workspace_slug text,p_expected_agent_codes text[],p_child_run_ids text[]) returns jsonb
 language plpgsql stable set search_path='' as $$
 declare wid uuid; oid uuid; gate jsonb; actual int;
 begin
 select id into wid from agent_ops.workspaces where slug=p_workspace_slug;
 if wid is null or ((select auth.uid()) is null and current_user not in('postgres','service_role')) or (current_user not in('postgres','service_role') and not exists(select 1 from agent_ops.members where workspace_id=wid and user_id=(select auth.uid()) and active)) then raise exception 'Workspace access required' using errcode='42501'; end if;
 if p_expected_agent_codes is null or p_child_run_ids is null or cardinality(p_expected_agent_codes) not between 2 and 3 or cardinality(p_expected_agent_codes)<>cardinality(p_child_run_ids) or array_position(p_expected_agent_codes,null) is not null or array_position(p_child_run_ids,null) is not null or (select count(distinct x) from unnest(p_expected_agent_codes)x)<>cardinality(p_expected_agent_codes) or (select count(distinct x) from unnest(p_child_run_ids)x)<>cardinality(p_child_run_ids) or exists(select 1 from unnest(p_child_run_ids)x where x!~ '^[0-9a-fA-F-]{36}$') then raise exception 'Nonempty unique agent and run ID pairs are required' using errcode='22023'; end if;
 select c.orchestration_id into oid from agent_ops.chat_turns c where c.workspace_id=wid and c.run_id::text=p_child_run_ids[1] and c.parent_turn_id is not null;
 if oid is null then return jsonb_build_object('complete',false,'reason','NO_RUNTIME_ORCHESTRATION'); end if;
 select count(*) into actual from unnest(p_expected_agent_codes,p_child_run_ids)x(agent,runid) join agent_ops.chat_turns c on c.workspace_id=wid and c.run_id::text=x.runid and c.orchestration_id=oid and c.parent_turn_id is not null join agent_ops.chat_threads th on th.workspace_id=c.workspace_id and th.id=c.thread_id and th.agent_code=x.agent;
 gate:=agent_ops.orchestration_gate(wid,oid);
 return gate||jsonb_build_object('complete',coalesce((gate->>'complete')::boolean,false) and actual=cardinality(p_child_run_ids) and (gate->>'expectedCount')::int=cardinality(p_child_run_ids));
 end $$;

create or replace function public.agent_ops_recover_chat(p_user_id uuid) returns jsonb
 language plpgsql set search_path='' as $$
 declare t agent_ops.chat_turns%rowtype; recovered jsonb:='[]'::jsonb; result jsonb;
 begin
 if current_user not in('postgres','service_role') then raise exception 'Runtime service required' using errcode='42501'; end if;
 for t in select * from agent_ops.chat_turns where user_id=p_user_id and status='running' and started_at<clock_timestamp()-interval '3 minutes' order by started_at for update skip locked limit 10 loop
  result:=public.agent_ops_finish_chat(t.id,t.user_id,null,'WORKER_TIMEOUT',null,extract(epoch from(clock_timestamp()-t.started_at))*1000,null,null);
  recovered:=recovered||jsonb_build_array(result);
 end loop;
 return jsonb_build_object('recovered',recovered);
 end $$;

create or replace function public.agent_ops_chat_state(p_workspace_slug text default 'agent-factory',p_thread_id uuid default null) returns jsonb
 language plpgsql stable set search_path='' as $$
 declare wid uuid; mr text;
 begin
 select w.id,m.role into wid,mr from agent_ops.workspaces w join agent_ops.members m on m.workspace_id=w.id where w.slug=p_workspace_slug and m.user_id=(select auth.uid()) and m.active;
 if wid is null then raise exception 'Agent Factory membership required' using errcode='42501'; end if;
 if p_thread_id is not null and not exists(select 1 from agent_ops.chat_threads where workspace_id=wid and id=p_thread_id and user_id=(select auth.uid())) then raise exception 'Conversation unavailable' using errcode='42501'; end if;
 return jsonb_build_object('role',mr,'settings',(select to_jsonb(s)-'workspace_id' from agent_ops.runtime_settings s where workspace_id=wid),
 'agents',(select coalesce(jsonb_agg(jsonb_build_object('code',a.code,'name',a.name,'short_name',a.short_name,'is_orchestrator',a.is_orchestrator is true,'lifecycle',a.lifecycle,'runtime_status',a.runtime_status,'implementation_verified_at',a.implementation_verified_at,'requires_run_log',a.requires_run_log,'logging_contract_version',a.logging_contract_version,'dna_valid',a.requires_run_log and nullif(btrim(a.agent_dna_md),'') is not null and position('runId' in a.agent_dna_md)>0 and position('RUN_LOG' in a.agent_dna_md)>0) order by a.code),'[]'::jsonb) from agent_ops.agents a where workspace_id=wid),
 'threads',(select coalesce(jsonb_agg(to_jsonb(t) order by created_at desc),'[]'::jsonb) from(select id,agent_code,title,created_at from agent_ops.chat_threads where workspace_id=wid and user_id=(select auth.uid()) order by created_at desc limit 100)t),
 'turns',(select coalesce(jsonb_agg(to_jsonb(t) order by created_at,id),'[]'::jsonb) from(select t.id,t.thread_id,t.run_id,th.agent_code,t.user_content,t.assistant_content,t.status,t.error_code,t.execution_mode,t.model,t.duration_ms,t.input_tokens,t.output_tokens,t.context_refs,t.created_at,t.started_at,t.completed_at,t.orchestration_id,t.parent_turn_id,
 agent_ops.chat_receipt(t.workspace_id,t.id)||case when t.orchestration_id is not null and t.parent_turn_id is null then jsonb_build_object('gate',agent_ops.orchestration_gate(t.workspace_id,t.orchestration_id),'children',agent_ops.orchestration_gate(t.workspace_id,t.orchestration_id)->'children') else '{}'::jsonb end as receipt
 from agent_ops.chat_turns t join agent_ops.chat_threads th on th.workspace_id=t.workspace_id and th.id=t.thread_id where t.workspace_id=wid and t.thread_id=p_thread_id and t.user_id=(select auth.uid()) order by t.created_at desc,t.id desc limit 100)t),
 'pending',(select to_jsonb(t) from(select id,thread_id,status,created_at,orchestration_id,parent_turn_id from agent_ops.chat_turns where workspace_id=wid and user_id=(select auth.uid()) and status in('queued','running') order by (parent_turn_id is null) desc,created_at limit 1)t));
 end $$;

CREATE OR REPLACE FUNCTION public.agent_ops_submit_chat(p_workspace_slug text, p_agent_code text, p_thread_id uuid, p_request_id uuid, p_message text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$ declare wid uuid; tid uuid; result agent_ops.chat_turns%rowtype; begin
if (select auth.uid()) is null or p_request_id is null or p_message is null or length(btrim(p_message)) not between 1 and 8000 then raise exception 'A signed-in user, request ID and 1-8000 characters are required' using errcode='22023'; end if;
select id into wid from agent_ops.workspaces where slug=p_workspace_slug and collection_status<>'paused';
if wid is null or not exists(select 1 from agent_ops.members where workspace_id=wid and user_id=(select auth.uid()) and active and role in('editor','reviewer','admin')) then raise exception 'Editor access required' using errcode='42501'; end if;
perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(wid::text||':chat:'||(select auth.uid())::text,0));
select * into result from agent_ops.chat_turns where workspace_id=wid and user_id=(select auth.uid()) and request_id=p_request_id;
if found then
if result.orchestration_id is not null or result.user_content<>btrim(p_message) or (p_thread_id is not null and result.thread_id<>p_thread_id) or not exists(select 1 from agent_ops.chat_threads where workspace_id=wid and id=result.thread_id and agent_code=p_agent_code) then raise exception 'Request ID reused with different content' using errcode='23505'; end if;
return jsonb_build_object('id',result.id,'threadId',result.thread_id,'status',result.status,'runId',result.run_id,'agentId',p_agent_code,'deduplicated',true); end if;
if not exists(select 1 from agent_ops.agents where workspace_id=wid and code=p_agent_code and lifecycle<>'deprecated' and runtime_status<>'disabled') then raise exception 'Agent unavailable' using errcode='42501'; end if;
tid:=p_thread_id;
if tid is null then insert into agent_ops.chat_threads(workspace_id,agent_code,title) values(wid,p_agent_code,left(btrim(p_message),90)) returning id into tid;
elsif not exists(select 1 from agent_ops.chat_threads where workspace_id=wid and id=tid and user_id=(select auth.uid()) and agent_code=p_agent_code) then raise exception 'Conversation unavailable or agent mismatch' using errcode='42501'; end if;
insert into agent_ops.chat_turns(workspace_id,thread_id,request_id,user_content) values(wid,tid,p_request_id,btrim(p_message)) returning * into result;
return jsonb_build_object('id',result.id,'threadId',tid,'status',result.status,'runId',result.run_id,'agentId',p_agent_code,'deduplicated',false); end $function$;

CREATE OR REPLACE FUNCTION public.agent_ops_operations_write(p_workspace_slug text, p_runs jsonb, p_source_id text, p_source_kind text DEFAULT 'import'::text, p_environment text DEFAULT 'production'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare wid uuid; r jsonb; previous agent_ops.operation_runs%rowtype; added int:=0; duplicates int:=0;
begin
 if p_source_kind is null or p_source_kind not in('runtime','manual','import') or p_environment is null or p_environment not in('production','staging','test') then raise exception 'Invalid source/environment' using errcode='22023'; end if;
 select id into wid from agent_ops.workspaces where slug=p_workspace_slug and collection_status<>'paused';
 if wid is null then raise exception 'Workspace not found or access denied' using errcode='42501'; end if;
 if current_user not in('postgres','service_role') then
  if (select auth.uid()) is null or p_source_kind not in('manual','import') or p_environment<>'production' or not exists(select 1 from agent_ops.members where workspace_id=wid and user_id=(select auth.uid()) and active and role in('editor','admin')) then raise exception 'Workspace editor/admin required; runtime writes are server-only' using errcode='42501'; end if;
 end if;
 if jsonb_typeof(p_runs) is distinct from 'array' then raise exception 'runs must be an array' using errcode='22023'; end if;
 if jsonb_array_length(p_runs) not between 1 and 200 or octet_length(p_runs::text)>2097152 then raise exception 'Limit 200 runs / 2 MiB per request' using errcode='22023'; end if;
 if p_source_id is null or p_source_id !~ '^[A-Za-z0-9_.:-]{1,128}$' then raise exception 'Invalid source ID' using errcode='22023'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(wid::text||':operations:'||p_environment,0));
 for r in select value from jsonb_array_elements(p_runs) loop
  select * into previous from agent_ops.operation_runs where workspace_id=wid and environment=p_environment and run_id=r->>'runId';
  if found then
   if previous.payload is distinct from r or previous.source_kind is distinct from p_source_kind or previous.source_id is distinct from p_source_id then raise exception 'runId already has different content' using errcode='23505'; end if;
   duplicates:=duplicates+1;
  else
   insert into agent_ops.operation_runs(workspace_id,run_id,environment,source_kind,source_id,payload,created_by) values(wid,r->>'runId',p_environment,p_source_kind,p_source_id,r,(select auth.uid()));
   added:=added+1;
  end if;
 end loop;
 return jsonb_build_object('inserted',added,'deduplicated',duplicates,'environment',p_environment);
end $function$;

CREATE OR REPLACE FUNCTION agent_ops.guard_operation_run()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare r jsonb; s jsonb; k text; t timestamptz; turn agent_ops.chat_turns%rowtype; parentrun text;
begin
 if tg_op<>'INSERT' then raise exception 'RUN_LOG is append-only' using errcode='55000'; end if;
 r:=new.payload;
 if jsonb_typeof(r) is distinct from 'object' or pg_catalog.octet_length(r::text)>262144 then raise exception 'RUN_LOG must be an object <=256 KiB' using errcode='22023'; end if;
 if not(r ?& array['runId','agentId','startedAt','status','trigger','parentAgentId','steps']) or exists(select 1 from jsonb_object_keys(r) as keys(key) where keys.key <> all(array['runId','agentId','startedAt','status','trigger','parentAgentId','steps'])) then raise exception 'Unknown or missing RUN_LOG fields; raw content is prohibited' using errcode='22023'; end if;
 foreach k in array array['runId','agentId'] loop
  if jsonb_typeof(r->k) is distinct from 'string' or (r->>k) !~ '^[A-Za-z0-9_.:-]{1,128}$' or (r->>k) like 'demo-%' then raise exception 'Invalid or demo identifier' using errcode='22023'; end if;
 end loop;
 if new.run_id is distinct from r->>'runId' then raise exception 'runId mismatch' using errcode='22023'; end if;
 if jsonb_typeof(r->'parentAgentId') is distinct from 'null' and(jsonb_typeof(r->'parentAgentId') is distinct from 'string' or (r->>'parentAgentId') !~ '^[A-Za-z0-9_.:-]{1,128}$' or (r->>'parentAgentId') like 'demo-%') then raise exception 'Invalid parentAgentId' using errcode='22023'; end if;
 if jsonb_typeof(r->'startedAt') is distinct from 'string' or (r->>'startedAt') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$' then raise exception 'startedAt requires ISO 8601 with timezone' using errcode='22023'; end if;
 t:=(r->>'startedAt')::timestamptz;
 if t>statement_timestamp()+interval '5 minutes' then raise exception 'Future timestamp' using errcode='22023'; end if;
 if coalesce(r->>'status','') not in('success','failed','escalated','abandoned') or coalesce(r->>'trigger','') not in('user','schedule','agent') then raise exception 'Invalid status/trigger' using errcode='22023'; end if;
 if jsonb_typeof(r->'steps') is distinct from 'array' then raise exception 'steps must be an array' using errcode='22023'; end if;
 if jsonb_array_length(r->'steps')>100 then raise exception 'Maximum 100 steps' using errcode='22023'; end if;
 for s in select value from jsonb_array_elements(r->'steps') loop
  if jsonb_typeof(s) is distinct from 'object' then raise exception 'Each step must be an object' using errcode='22023'; end if;
  if not(s ?& array['stage','skillId','durationSec','waitSec','status','retries']) or exists(select 1 from jsonb_object_keys(s) as keys(key) where keys.key <> all(array['stage','skillId','durationSec','waitSec','status','retries'])) then raise exception 'Unknown or missing step fields' using errcode='22023'; end if;
  if coalesce(s->>'stage','') not in('intake','routing','retrieval','execution','validation','approval','delivery') or coalesce(s->>'status','') not in('ok','fail','retry') then raise exception 'Invalid stage/status' using errcode='22023'; end if;
  if jsonb_typeof(s->'skillId') is distinct from 'null' and(jsonb_typeof(s->'skillId') is distinct from 'string' or (s->>'skillId') !~ '^[A-Za-z0-9_.:-]{1,128}$' or (s->>'skillId') like 'demo-%') then raise exception 'Invalid skillId' using errcode='22023'; end if;
  foreach k in array array['durationSec','waitSec','retries'] loop
   if jsonb_typeof(s->k) is distinct from 'number' then raise exception 'Timing and retry fields must be measured numbers' using errcode='22023'; end if;
   if (s->>k)::numeric<0 or (s->>k)::numeric>31536000 then raise exception 'Numeric field out of range' using errcode='22023'; end if;
  end loop;
  if (s->>'retries')::numeric<>trunc((s->>'retries')::numeric) or (s->>'retries')::numeric>10000 or ((s->>'status')='retry' and (s->>'retries')::numeric=0) then raise exception 'Invalid retry count' using errcode='22023'; end if;
 end loop;

 if new.source_id='agent-ops-chat' then
  if new.source_kind<>'runtime' or new.source_turn_id is null then raise exception 'Reserved runtime source requires verified chat turn' using errcode='42501'; end if;
  select * into turn from agent_ops.chat_turns where workspace_id=new.workspace_id and id=new.source_turn_id and run_id::text=new.run_id and status in('succeeded','failed');
  if not found then raise exception 'No matching completed runtime turn' using errcode='23505'; end if;
  select run_id::text into parentrun from agent_ops.chat_turns where workspace_id=turn.workspace_id and id=turn.parent_turn_id;
  if new.payload is distinct from agent_ops.turn_run_payload(turn) or new.created_by is distinct from turn.user_id or new.orchestration_id is distinct from turn.orchestration_id or new.parent_run_id is distinct from parentrun then raise exception 'Runtime source/payload mismatch' using errcode='23505'; end if;
 elsif new.source_turn_id is not null or new.orchestration_id is not null or new.parent_run_id is not null or exists(select 1 from agent_ops.chat_turns where workspace_id=new.workspace_id and run_id::text=new.run_id) then
  raise exception 'Chat run IDs and links are reserved for runtime logger' using errcode='23505';
 end if;
 return new;
end $function$;

-- Repair contract metadata only: this never asserts agent implementation or execution readiness.
update agent_ops.runtime_contracts c
 set config=jsonb_set(c.config,'{requiredReturnFields}','["agentId","runId","status","logging"]'::jsonb),
 contract_md=c.contract_md||case when position('Exact runtime receipt v2' in c.contract_md)>0 then '' else E'\n## Exact runtime receipt v2\nReturn agentId, runId, status and logging after the server verifies the exact runtime source row. Orchestrators require a nonempty unique child set in the same orchestration; every child agentId/runId pair must be successful and logging=logged before parent success. Client claims are never evidence.\n' end
 where c.workspace_id=(select id from agent_ops.workspaces where slug='agent-factory') and c.contract_key='run-log' and c.version='1.0.0' and c.active;

-- New routines are invoker-rights. A client cannot call claim/finish/recover/verify.
revoke all on function agent_ops.turn_run_payload(agent_ops.chat_turns),agent_ops.chat_receipt(uuid,uuid),agent_ops.orchestration_gate(uuid,uuid) from public,anon;
grant execute on function agent_ops.turn_run_payload(agent_ops.chat_turns),agent_ops.chat_receipt(uuid,uuid),agent_ops.orchestration_gate(uuid,uuid) to authenticated,service_role;
revoke all on function public.agent_ops_submit_orchestration(text,text,text[],uuid,text) from public,anon,service_role;
grant execute on function public.agent_ops_submit_orchestration(text,text,text[],uuid,text) to authenticated;
revoke all on function public.agent_ops_verify_chat(uuid,uuid),public.agent_ops_recover_chat(uuid),public.agent_ops_claim_chat(uuid,uuid,boolean),public.agent_ops_finish_chat(uuid,uuid,text,text,text,numeric,bigint,bigint) from public,anon,authenticated;
grant execute on function public.agent_ops_verify_chat(uuid,uuid),public.agent_ops_recover_chat(uuid),public.agent_ops_claim_chat(uuid,uuid,boolean),public.agent_ops_finish_chat(uuid,uuid,text,text,text,numeric,bigint,bigint) to service_role;
revoke all on function public.agent_ops_submit_chat(text,text,uuid,uuid,text),public.agent_ops_chat_state(text,uuid),public.agent_ops_orchestrator_gate(text,text[],text[]) from public,anon;
grant execute on function public.agent_ops_submit_chat(text,text,uuid,uuid,text),public.agent_ops_chat_state(text,uuid) to authenticated;
grant execute on function public.agent_ops_orchestrator_gate(text,text[],text[]) to authenticated,service_role;

comment on table agent_ops.orchestrations is 'Actual submitted multi-agent work. Immutable owner-scoped definition; not proof of execution.';
comment on column agent_ops.operation_runs.source_turn_id is 'Runtime producer binding checked against exact terminal turn/payload; never client evidence.';
comment on column agent_ops.chat_turns.orchestration_id is 'Durable parent/child linkage; completion gate rechecks every unique child runtime receipt.';

-- Bounded recovery handles abandoned accepted work without invoking an AI provider.
-- A queued timeout measures this actual failure handler; queue time is measured separately.
create or replace function public.agent_ops_recover_stale_chat(p_workspace_slug text default 'agent-factory',p_limit integer default 25)
 returns jsonb language plpgsql set search_path='' as $$
 declare wid uuid; t agent_ops.chat_turns%rowtype; a text; began timestamptz; err text; result jsonb; recovered jsonb:='[]'::jsonb;
 begin
 if current_user not in('postgres','service_role') then raise exception 'Runtime service required' using errcode='42501'; end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Limit must be 1–100' using errcode='22023'; end if;
 select id into wid from agent_ops.workspaces where slug=p_workspace_slug;
 if wid is null then raise exception 'Workspace unavailable' using errcode='22023'; end if;
 for t in select * from agent_ops.chat_turns where workspace_id=wid and ((status='running' and started_at<clock_timestamp()-interval '3 minutes') or(status='queued' and created_at<clock_timestamp()-interval '10 minutes')) order by created_at for update skip locked limit p_limit loop
  begin
   if t.status='queued' then
    began:=clock_timestamp(); err:='QUEUE_TIMEOUT';
    select agent_code into a from agent_ops.chat_threads where workspace_id=t.workspace_id and id=t.thread_id;
    update agent_ops.chat_turns set status='running',started_at=began,execution_mode='database_command' where workspace_id=t.workspace_id and id=t.id;
    insert into agent_ops.execution_events(workspace_id,producer,event_key,run_id,agent_code,agent_version,event_type,environment,occurred_at)
    values(t.workspace_id,'agent-ops-chat',t.id::text||':run.start',t.run_id,a,'chat-runtime-v2','run.started','production',began);
    insert into agent_ops.execution_events(workspace_id,producer,event_key,run_id,span_id,agent_code,agent_version,skill_code,skill_version,step_name,event_type,environment,occurred_at)
    values(t.workspace_id,'agent-ops-chat',t.id::text||':skill.start',t.run_id,t.span_id,a,'chat-runtime-v2','chat-response','1.0.0','queue-timeout-handling','skill.started','production',began);
   else began:=t.started_at; err:='WORKER_TIMEOUT'; end if;
   result:=public.agent_ops_finish_chat(t.id,t.user_id,null,err,null,extract(epoch from(clock_timestamp()-began))*1000,null,null);
   recovered:=recovered||jsonb_build_array(result-'answer');
  exception when others then
   -- Preserve the pending turn for a later retry; pg_cron records this warning.
   raise warning 'Agent Ops recovery failed for turn % (SQLSTATE %)',t.id,sqlstate;
  end;
 end loop;
 return jsonb_build_object('recovered',recovered,'count',jsonb_array_length(recovered));
 end $$;
revoke all on function public.agent_ops_recover_stale_chat(text,integer) from public,anon,authenticated;
grant execute on function public.agent_ops_recover_stale_chat(text,integer) to service_role;

-- Only this named job is created/updated. Existing unrelated schedules are untouched.
select cron.schedule('agent-ops-runtime-recovery','* * * * *',$cron$select public.agent_ops_recover_stale_chat('agent-factory',25);$cron$);

commit;
