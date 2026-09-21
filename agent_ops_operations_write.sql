CREATE OR REPLACE FUNCTION public.agent_ops_operations_write(p_workspace_slug text, p_runs jsonb, p_source_id text, p_source_kind text DEFAULT 'import'::text, p_environment text DEFAULT 'production'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare wid uuid; r jsonb; previous jsonb; added int:=0; duplicates int:=0;
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
  select payload into previous from agent_ops.operation_runs where workspace_id=wid and environment=p_environment and run_id=r->>'runId';
  if found then
   if previous is distinct from r then raise exception 'runId already has different content' using errcode='23505'; end if;
   duplicates:=duplicates+1;
  else
   insert into agent_ops.operation_runs(workspace_id,run_id,environment,source_kind,source_id,payload,created_by) values(wid,r->>'runId',p_environment,p_source_kind,p_source_id,r,(select auth.uid()));
   added:=added+1;
  end if;
 end loop;
 return jsonb_build_object('inserted',added,'deduplicated',duplicates,'environment',p_environment);
end $function$

