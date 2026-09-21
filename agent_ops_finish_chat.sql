CREATE OR REPLACE FUNCTION public.agent_ops_finish_chat(p_turn_id uuid, p_user_id uuid, p_answer text, p_error_code text, p_model text, p_duration_ms numeric, p_input_tokens bigint DEFAULT NULL::bigint, p_output_tokens bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare t agent_ops.chat_turns%rowtype; a text; done timestamptz:=clock_timestamp(); ev text; payload jsonb; wait_seconds numeric;
begin
select * into t from agent_ops.chat_turns where id=p_turn_id and user_id=p_user_id for update;
if not found then raise exception 'Turn unavailable' using errcode='42501'; end if;
if t.status<>'running' then
  return jsonb_build_object('status',t.status,'id',t.id,'runId',t.run_id,'logging',
    case when exists(select 1 from agent_ops.operation_runs r where r.workspace_id=t.workspace_id and r.environment='production' and r.run_id=t.run_id::text) then 'logged' else 'logging_failed' end);
end if;
if p_error_code is null and (p_answer is null or length(btrim(p_answer))=0) then raise exception 'Empty result' using errcode='22023'; end if;
if p_error_code is not null and p_error_code !~ '^[A-Z0-9_]{1,80}$' then raise exception 'Invalid error code' using errcode='22023'; end if;
if p_duration_ms is null or p_duration_ms<0 or coalesce(p_input_tokens,0)<0 or coalesce(p_output_tokens,0)<0 then raise exception 'Invalid metrics' using errcode='22023'; end if;
select agent_code into a from agent_ops.chat_threads where workspace_id=t.workspace_id and id=t.thread_id;
ev:=case when p_error_code is null then 'succeeded' else 'failed' end;
update agent_ops.chat_turns set status=ev,assistant_content=case when p_error_code is null then p_answer else null end,error_code=p_error_code,model=left(p_model,200),duration_ms=p_duration_ms,input_tokens=p_input_tokens,output_tokens=p_output_tokens,completed_at=done where workspace_id=t.workspace_id and id=t.id;
insert into agent_ops.execution_events(workspace_id,producer,event_key,run_id,span_id,agent_code,agent_version,skill_code,skill_version,step_name,event_type,environment,occurred_at,duration_ms,input_tokens,output_tokens,error_code)
values(t.workspace_id,'agent-ops-chat',t.id::text||':skill.end',t.run_id,t.span_id,a,'chat-runtime-v1','chat-response','1.0.0','chat-response','skill.'||ev,'production',done,p_duration_ms,p_input_tokens,p_output_tokens,p_error_code);
insert into agent_ops.execution_events(workspace_id,producer,event_key,run_id,agent_code,agent_version,event_type,environment,occurred_at,duration_ms,input_tokens,output_tokens,error_code)
values(t.workspace_id,'agent-ops-chat',t.id::text||':run.end',t.run_id,a,'chat-runtime-v1','run.'||ev,'production',done,p_duration_ms,p_input_tokens,p_output_tokens,p_error_code);
wait_seconds:=greatest(0,extract(epoch from(coalesce(t.started_at,t.created_at)-t.created_at)));
payload:=jsonb_build_object(
 'runId',t.run_id::text,
 'agentId',a,
 'startedAt',to_char(coalesce(t.started_at,t.created_at) at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
 'status',case when p_error_code is null then 'success' else 'failed' end,
 'trigger','user',
 'parentAgentId',null,
 'steps',jsonb_build_array(jsonb_build_object(
   'stage','execution',
   'skillId','chat-response',
   'durationSec',round((p_duration_ms/1000.0)::numeric,3),
   'waitSec',round(wait_seconds::numeric,3),
   'status',case when p_error_code is null then 'ok' else 'fail' end,
   'retries',0
 ))
);
insert into agent_ops.operation_runs(workspace_id,run_id,environment,source_kind,source_id,payload,created_by)
values(t.workspace_id,t.run_id::text,'production','runtime','agent-ops-chat',payload,p_user_id)
on conflict(workspace_id,run_id,environment) do nothing;
return jsonb_build_object('id',t.id,'status',ev,'runId',t.run_id,'logging',
 case when exists(select 1 from agent_ops.operation_runs r where r.workspace_id=t.workspace_id and r.environment='production' and r.run_id=t.run_id::text) then 'logged' else 'logging_failed' end);
end $function$

