CREATE OR REPLACE FUNCTION public.agent_ops_chat_state(p_workspace_slug text DEFAULT 'agent-factory'::text, p_thread_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$ declare wid uuid; mr text; begin
select w.id,m.role into wid,mr from agent_ops.workspaces w join agent_ops.members m on m.workspace_id=w.id where w.slug=p_workspace_slug and m.user_id=(select auth.uid()) and m.active;
if wid is null then raise exception 'Agent Factory membership required' using errcode='42501'; end if;
if p_thread_id is not null and not exists(select 1 from agent_ops.chat_threads where workspace_id=wid and id=p_thread_id) then raise exception 'Conversation unavailable' using errcode='42501'; end if;
return jsonb_build_object('role',mr,'settings',(select to_jsonb(s)-'workspace_id' from agent_ops.runtime_settings s where workspace_id=wid),'threads',(select coalesce(jsonb_agg(to_jsonb(t) order by created_at desc),'[]'::jsonb) from(select id,agent_code,title,created_at from agent_ops.chat_threads where workspace_id=wid order by created_at desc limit 100)t),'turns',(select coalesce(jsonb_agg(to_jsonb(t) order by created_at,id),'[]'::jsonb) from(select id,thread_id,run_id,user_content,assistant_content,status,error_code,execution_mode,model,duration_ms,input_tokens,output_tokens,context_refs,created_at,started_at,completed_at from agent_ops.chat_turns where workspace_id=wid and thread_id=p_thread_id order by created_at desc,id desc limit 100)t),'pending',(select to_jsonb(t) from(select id,thread_id,status,created_at from agent_ops.chat_turns where workspace_id=wid and status in('queued','running') order by created_at limit 1)t));
end $function$

