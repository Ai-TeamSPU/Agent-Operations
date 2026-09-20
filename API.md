# Agent Operations — API และการต่อ runtime

## ปลายทางที่สร้างแล้ว

โครงการ `doxunxbgqmybyckczucg` · Workspace `agent-factory`

Base URL: `https://doxunxbgqmybyckczucg.supabase.co/rest/v1/rpc/`

ทุกคำขอใช้ POST JSON พร้อม `apikey` และ `Authorization: Bearer <user access token>` ของผู้มีสิทธิ์ ข้อความในวงเล็บเป็นคำอธิบาย ไม่ใช่ token จริง ไม่มี secret credentials ในชุดไฟล์นี้

### อ่านข้อมูล: `agent_ops_operations_snapshot`

พารามิเตอร์ `p_workspace_slug` เป็น slug Workspace ค่าเริ่มต้น `agent-factory` ผู้ใช้ต้องมี membership active

ผลลัพธ์ schemaVersion 3 มี `generatedAt`, `workspace`, `memberRole`, `scope`, `coverage`, `registry: {agents,skills}` และ `runs: [{id,data}]` เริ่มต้นว่าง ไม่มี seed ทะเบียนใช้เฉพาะรายการที่ admin ยืนยันว่ามี implementation และสถานะ active; mapping ต้อง verified

จำนวนงานสูงสุด 20,000 หากเกินคืน error ไม่ตัดข้อมูลเงียบ ๆ ค่า `scope.truncated` ต้อง false หน้าเว็บไม่ควรแสดงข้อมูลบางส่วนเป็นยอดครบ

### บันทึกงาน: `agent_ops_operations_write`

พารามิเตอร์:

- `p_workspace_slug`: Workspace จริงที่ได้รับอนุญาต
- `p_runs`: array ของ RUN_LOG ที่เกิดจริง 1–200 งาน และรวมไม่เกิน 2 MiB ต่อคำขอ
- `p_source_id`: รหัสแหล่งข้อมูลที่ไม่ใช่ชื่อบุคคล/อีเมล ความยาว 1–128 อักขระ ตามรูปแบบที่กำหนด
- `p_source_kind`: runtime / manual / import ค่าเริ่มต้น import
- `p_environment`: production / staging / test ค่าเริ่มต้น production

งานละไม่เกิน 100 steps และ 256 KiB ยอมรับเฉพาะ field ตาม schema ไม่เก็บ prompt, เนื้อหางาน หรือข้อมูลส่วนบุคคล source_kind runtime และ environment นอก production ใช้ได้เฉพาะ trusted server credential ฝั่งผู้ใช้ editor/admin เขียนได้เฉพาะ manual/import production

คืน `{inserted, deduplicated, environment}` การเรียกหนึ่งก้อนเป็นธุรกรรมเดียว runId เดิมที่เนื้อหาต่างกันปฏิเสธ หากส่งหลายคำขอ อาจบันทึกไปแล้วบางคำขอก่อนพบปัญหา อ่านกลับก่อน retry และรักษา runId เดิม

### ลงทะเบียน: `agent_ops_operations_register`

พารามิเตอร์ `p_workspace_slug`, `p_registry` ตาม `agent-registry.schema.json` ต้อง active admin หรือ trusted server

ต้องส่งเฉพาะสิ่งที่สร้างแล้ว มี version และ implementationEvidence จริง พร้อม confirmedCreated true การเพิ่มรายการไม่ได้สั่งสร้าง Agent/Skill หรือเริ่ม runtime API ไม่เพิ่ม default mapping ไม่สร้าง placeholder Skill ที่ยังไม่มี และไม่ลบ Agent ที่ไม่ได้ส่งมาในคำขอ

คืน `agentsUpserted`, `skillsUpserted`, `runtimeConnectionChanged:false`

## การใช้ client ฝั่ง server

`agent-ops-client.mjs` ไม่มี dependency เพิ่ม ใช้ Fetch/AbortSignal ใน Node.js 20+ การ import โมดูลไม่ติดต่อ Supabase และไม่สร้างข้อมูล

โค้ดต่อไปนี้อ้างตัวแปรที่ระบบหลังบ้านจัดเตรียมแล้ว ไม่ใช่ชุดข้อมูลตัวอย่างหรือคำสั่งที่รันทันที:

```js
import { AgentOperationsClient } from './agent-ops-client.mjs';

const client = new AgentOperationsClient({
  url: serverConfig.supabaseUrl,
  apiKey: serverConfig.apiKey,
  accessToken: serverCredentials.accessToken,
  workspace: serverConfig.workspace
});

const result = await client.writeRuns(actualRunLogs, {
  sourceId: actualSourceId,
  sourceKind: 'runtime',
  environment: 'production'
});
```

`serverCredentials` ต้องอยู่ในระบบหลังบ้านที่ได้รับอนุญาตเท่านั้น ห้ามนำ trusted server/service_role credential ไปใส่ HTML, public environment variables, browser หรือ log ทั่วไป ฟังก์ชัน writeRuns ไม่สร้าง RUN_LOG เอง เมื่อ actualRunLogs ว่างจะไม่ส่งคำขอเขียน

Runtime ต้องวัดเวลาและผลลัพธ์จริง รวมถึงเวลารอและจำนวนทำซ้ำ แล้วส่งเฉพาะเหตุการณ์ที่เกิด หากไม่มีข้อมูลอย่าสร้างแถวเพื่อทดสอบความมีชีวิตของ dashboard

## สิทธิ์และการเปิดใช้กับทีม

`agent_ops.members` ใช้ user_id ของบัญชี Auth ที่เจ้าของระบบอนุมัติ ประกอบด้วย workspace_id, user_id, role และ active หน้าเว็บไม่มีสิทธิ์เพิ่มสมาชิกตัวเอง ไม่มี wildcard email/domain membership และไม่ได้ดึงสิทธิ์ HR มาทดแทน

ขณะส่งมอบยังไม่มีสมาชิก active ต้องเลือกอีเมลจริงของผู้ดูแลก่อน จากนั้นตรวจบัญชีเดิมและเพิ่ม membership เฉพาะบัญชีนั้นผ่านผู้ดูแลที่เชื่อถือได้ ไม่ต้องเปิด anon access เพื่อให้ dashboard โหลดได้

ให้ทีมใช้ผ่านเว็บไซต์ HTTPS ที่องค์กรควบคุม นำไฟล์ HTML ไปเผยแพร่ใน hosting ของทีมโดยคงการเข้าสู่ระบบและ RLS ไว้ ชุดนี้ยังไม่ได้เผยแพร่เป็นลิงก์เว็บไซต์ หากองค์กรใช้ SSO/MFA ให้เชื่อม Auth ของ host แทนการลดข้อกำหนดการเข้าสู่ระบบ

## สัญญาฝั่งหน้าเว็บ

`window.AgentOps.useAccessToken(token)` รับ user access token จาก Auth ของ host, `refresh()` อ่าน snapshot ใหม่, `signOut()` ล้าง session/ข้อมูลจากหน้า `getConnectionStatus()` รายงานสถานะ และ `getViewSummary()` คืน null ก่อนอ่านข้อมูลสำเร็จ

`connect({downloads, sample})` ใช้เสริมดาวน์โหลดหรือ AI ตามที่ host อนุมัติเท่านั้น ไม่ใช่ฐานข้อมูลจำลอง และไม่เปลี่ยนสิทธิ์ Supabase ไม่มี sample adapter ติดตั้งเริ่มต้น

API คืนข้อผิดพลาดเมื่อสิทธิ์ไม่พอ/ข้อมูลผิด ไม่ควรแปลง error เป็น empty success หาก connection ขาดต้องแสดงข้อมูลเก่าพร้อมป้ายว่าไม่ล่าสุด หรือสถานะอ่านไม่ได้ ไม่รายงานว่าศูนย์งานโดยไม่มี snapshot สำเร็จ

## หลักฐานโครงสร้างและ migration

Migrations ที่รันสำเร็จบนโครงการนี้:

- `agent_operations_run_log_connector`
- `agent_operations_verified_registry_only`

ชุดนี้ไม่แนบ SQL สำหรับรัน migrations ซ้ำโดยไม่ตรวจสภาพฐานข้อมูล `sql/verify.sql` ตรวจสถานะจริงและดึง definition ของ RPC ได้ ใช้ migration history ของโครงการเป็นต้นฉบับเมื่อจัดการโครงสร้างต่อ ไม่รัน DDL ซ้ำแบบคาดเดา
