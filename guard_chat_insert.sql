CREATE OR REPLACE FUNCTION agent_ops.guard_chat_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$ declare cfg agent_ops.runtime_settings%rowtype; begin
if (select auth.uid()) is null or new.user_id is distinct from (select auth.uid()) then raise exception 'Sign in to submit' using errcode='42501'; end if;
perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.workspace_id::text||':chat:'||new.user_id::text,0));
select * into cfg from agent_ops.runtime_settings where workspace_id=new.workspace_id;
if not found then raise exception 'Runtime unavailable' using errcode='42501'; end if;
if exists(select 1 from agent_ops.chat_turns where workspace_id=new.workspace_id and user_id=new.user_id and status in('queued','running')) then raise exception 'Finish or resolve the pending turn first' using errcode='55000'; end if;
if (select count(*) from agent_ops.chat_turns where workspace_id=new.workspace_id and user_id=new.user_id and created_at>now()-interval '1 minute')>=cfg.requests_per_minute or (select count(*) from agent_ops.chat_turns where workspace_id=new.workspace_id and user_id=new.user_id and created_at>now()-interval '24 hours')>=cfg.requests_per_day then raise exception 'Chat request limit reached' using errcode='54000'; end if;
return new; end $function$

