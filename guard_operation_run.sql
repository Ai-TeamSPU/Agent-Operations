CREATE OR REPLACE FUNCTION agent_ops.guard_operation_run()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare r jsonb; s jsonb; k text; t timestamptz;
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
 return new;
end $function$

