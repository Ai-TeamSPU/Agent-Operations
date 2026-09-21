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
if result.user_content<>btrim(p_message) or (p_thread_id is not null and result.thread_id<>p_thread_id) or not exists(select 1 from agent_ops.chat_threads where workspace_id=wid and id=result.thread_id and agent_code=p_agent_code) then raise exception 'Request ID reused with different content' using errcode='23505'; end if;
return jsonb_build_object('id',result.id,'threadId',result.thread_id,'status',result.status,'deduplicated',true); end if;
if not exists(select 1 from agent_ops.agents where workspace_id=wid and code=p_agent_code and lifecycle<>'deprecated' and runtime_status<>'disabled') then raise exception 'Agent unavailable' using errcode='42501'; end if;
tid:=p_thread_id;
if tid is null then insert into agent_ops.chat_threads(workspace_id,agent_code,title) values(wid,p_agent_code,left(btrim(p_message),90)) returning id into tid;
elsif not exists(select 1 from agent_ops.chat_threads where workspace_id=wid and id=tid and user_id=(select auth.uid()) and agent_code=p_agent_code) then raise exception 'Conversation unavailable or agent mismatch' using errcode='42501'; end if;
insert into agent_ops.chat_turns(workspace_id,thread_id,request_id,user_content) values(wid,tid,p_request_id,btrim(p_message)) returning * into result;
return jsonb_build_object('id',result.id,'threadId',tid,'status',result.status,'deduplicated',false); end $function$

