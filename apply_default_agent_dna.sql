CREATE OR REPLACE FUNCTION agent_ops.apply_default_agent_dna()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare c text; extra text:='';
begin
  if new.workspace_id is null then return new; end if;
  select contract_md into c
  from agent_ops.runtime_contracts
  where workspace_id=new.workspace_id and contract_key='run-log' and active
  order by created_at desc limit 1;
  if c is not null then
    new.logging_contract_version := coalesce(new.logging_contract_version,'1.0.0');
    new.requires_run_log := true;
    if new.is_orchestrator is true then
      extra := E'\n\n# Orchestrator Completion Gate\n- ก่อนประกาศว่างานรวมเสร็จ ต้องตรวจ Agent ลูกทุกตัวที่ถูกมอบหมาย\n- Agent ลูกทุกตัวต้องคืน runId และ logging = logged\n- ถ้าขาด runId หรือ logging ไม่ใช่ logged ให้สถานะงานรวมเป็น incomplete หรือ escalated และระบุ agentId ที่ยังขาด\n- ห้ามถือว่างานสำเร็จจากข้อความตอบอย่างเดียว ต้องมีหลักฐาน RUN_LOG ที่ระบบรับแล้ว\n- ห้ามสร้าง runId แทน Agent ลูกหรือเดาผลการบันทึก';
    end if;
    if nullif(trim(new.agent_dna_md),'') is null then
      new.agent_dna_md := '# Agent DNA — Operations Contract'||E'\n\n'||
        coalesce(nullif(trim(new.role_description),''),'ทำงานตามบทบาทที่กำหนด')||E'\n\n'||c||extra;
    end if;
  end if;
  return new;
end $function$

