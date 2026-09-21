CREATE OR REPLACE FUNCTION agent_ops.guard_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare s agent_ops.execution_events%rowtype;
begin
 if tg_op <> 'INSERT' then raise exception 'Execution events are append-only' using errcode='55000'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.workspace_id::text||':'||new.environment||':'||new.run_id::text,0));
 if new.occurred_at > now()+interval '5 minutes' then raise exception 'Event timestamp is in the future' using errcode='22023'; end if;
 if new.event_type <> 'run.started' then
  select * into s from agent_ops.execution_events e where e.workspace_id=new.workspace_id and e.environment=new.environment and e.run_id=new.run_id and e.event_type='run.started';
  if not found or s.agent_code<>new.agent_code or s.producer<>new.producer or s.source_kind<>new.source_kind or new.occurred_at<s.occurred_at then raise exception 'Matching run.started must arrive first' using errcode='23514'; end if;
 end if;
 if new.event_type like 'skill.%' and exists(select 1 from agent_ops.execution_events e where e.workspace_id=new.workspace_id and e.environment=new.environment and e.run_id=new.run_id and e.event_type in ('run.succeeded','run.failed','run.cancelled')) then raise exception 'Run is already closed' using errcode='23514'; end if;
 if new.event_type in ('skill.succeeded','skill.failed') then
  select * into s from agent_ops.execution_events e where e.workspace_id=new.workspace_id and e.environment=new.environment and e.run_id=new.run_id and e.span_id=new.span_id and e.event_type='skill.started';
  if not found or s.agent_code<>new.agent_code or s.skill_code<>new.skill_code or s.skill_version<>new.skill_version or new.occurred_at<s.occurred_at then raise exception 'Matching skill.started must arrive first' using errcode='23514'; end if;
 end if;
 return new;
end $function$

