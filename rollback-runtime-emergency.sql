-- Non-destructive emergency stop only. Preserves all accepted work and evidence.
-- Run only if rollout must be stopped. Do not restore unsafe old completion routines.
begin;
revoke execute on function public.agent_ops_submit_chat(text,text,uuid,uuid,text),public.agent_ops_submit_orchestration(text,text,text[],uuid,text) from authenticated;
-- Stop new claims but leave finish and the scoped recovery job available to settle existing work.
revoke execute on function public.agent_ops_claim_chat(uuid,uuid,boolean) from service_role;
commit;
-- Dashboard and owner history remain readable. A reviewed fixed forward migration should
-- regrant submit/claim after its acceptance checks. No data, memberships, HR or DL objects removed.
