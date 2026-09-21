-- Read-only production evidence. Run after migration and actual authenticated runtime calls.
-- Passing these checks is not a substitute for successful provider/browser acceptance.
select 'new_table_rls' as check_name,n.nspname,c.relname,c.relrowsecurity
from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='agent_ops' and c.relname in('chat_turns','chat_threads','operation_runs','orchestrations');

select p.proname,p.prosecdef as security_definer,
 has_function_privilege('anon',p.oid,'EXECUTE') as anonymous_execute,
 has_function_privilege('authenticated',p.oid,'EXECUTE') as authenticated_execute,
 has_function_privilege('service_role',p.oid,'EXECUTE') as service_execute
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.proname in('agent_ops_claim_chat','agent_ops_finish_chat','agent_ops_verify_chat','agent_ops_recover_chat','agent_ops_recover_stale_chat','agent_ops_submit_orchestration','agent_ops_chat_state') order by p.proname;

select a.code,a.lifecycle,a.runtime_status,a.implementation_verified_at,
 a.requires_run_log,a.logging_contract_version,
 a.requires_run_log and position('RUN_LOG' in a.agent_dna_md)>0 and position('runId' in a.agent_dna_md)>0 as dna_logging_present,
 exists(select 1 from agent_ops.runtime_contracts c where c.workspace_id=a.workspace_id and c.contract_key='run-log' and c.active and c.version=a.logging_contract_version) as contract_present,
 (select count(*) from agent_ops.operation_runs r where r.workspace_id=a.workspace_id and r.environment='production' and r.source_kind='runtime' and r.source_id='agent-ops-chat' and r.payload->>'agentId'=a.code and r.payload->>'status'='success' and r.source_turn_id is not null) as observed_successful_chat_runs
from agent_ops.agents a join agent_ops.workspaces w on w.id=a.workspace_id where w.slug='agent-factory' order by a.code;

-- Exact central row and runtime receipt comparison; excludes task contents and user identifiers.
select th.agent_code,t.id as turn_id,t.run_id,t.status,t.error_code,t.execution_mode,t.orchestration_id,t.parent_turn_id,
 r.environment,r.source_kind,r.source_id,r.source_turn_id,r.parent_run_id,r.payload,r.received_at,
 agent_ops.chat_receipt(t.workspace_id,t.id)->>'logging' as verified_logging
from agent_ops.chat_turns t join agent_ops.workspaces w on w.id=t.workspace_id
join agent_ops.chat_threads th on th.workspace_id=t.workspace_id and th.id=t.thread_id
left join agent_ops.operation_runs r on r.workspace_id=t.workspace_id and r.environment='production' and r.run_id=t.run_id::text
where w.slug='agent-factory' order by t.created_at desc limit 100;

select o.id as orchestration_id,agent_ops.orchestration_gate(o.workspace_id,o.id)-'children' as gate,
 (select jsonb_agg((x-'answer')-'threadId') from jsonb_array_elements(agent_ops.orchestration_gate(o.workspace_id,o.id)->'children')x) as child_receipts
from agent_ops.orchestrations o join agent_ops.workspaces w on w.id=o.workspace_id where w.slug='agent-factory' order by o.created_at desc limit 20;

-- Must be zero: terminal runs without verified source/payload binding.
select count(*) as terminal_unverified_count from agent_ops.chat_turns t join agent_ops.workspaces w on w.id=t.workspace_id
where w.slug='agent-factory' and t.status in('succeeded','failed') and agent_ops.chat_receipt(t.workspace_id,t.id)->>'logging'<>'logged';

-- Must be zero: mismatched duplicates. Primary key is workspace/environment/run_id.
select workspace_id,environment,run_id,count(*) from agent_ops.operation_runs group by workspace_id,environment,run_id having count(*)>1;
select jobid,jobname,schedule,command,active from cron.job where jobname='agent-ops-runtime-recovery';
select d.status,d.start_time,d.end_time,d.return_message from cron.job_run_details d join cron.job j on j.jobid=d.jobid where j.jobname='agent-ops-runtime-recovery' order by d.start_time desc limit 5;
