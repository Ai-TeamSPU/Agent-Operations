# Production Readiness Report — Agent Operations

วันที่ตรวจ: 21 กันยายน 2569 (2026-09-21) • Supabase `doxunxbgqmybyckczucg` • Repository `Ai-TeamSPU/Agent-Operations`

**ผลตัดสิน: NOT PRODUCTION READY — Backend deploy แล้ว แต่ยังไม่มีหลักฐาน Runtime ผ่านผู้ใช้จริง และหน้าเว็บใหม่ยังไม่เผยแพร่**

ไม่สร้าง synthetic data ลง Supabase ไม่ใส่ประวัติจำลองใน Dashboard และไม่เปลี่ยน Agent เป็นพร้อมใช้งานเพื่อให้สถานะดูผ่าน

## 1. สถานะที่ตรวจพบและสิ่งที่ทำแล้ว

| ประเด็น | ก่อนดำเนินการ | หลังดำเนินการ / หลักฐาน |
|---|---|---|
| Registry / DNA | Agent 16 ตัว มี DNA, requires_run_log=true, contract 1.0.0; draft/unverified ทั้งหมด | ตรวจครบ 16 ตัว; คงสถานะ unverified ทั้งหมด เพราะยังไม่มี Runtime proof รายตัว; รายละเอียด `evidence/baseline-agent-registry-dna.json` |
| Logging Contract | requiredReturnFields ยังไม่ระบุ agentId | กำหนด `agentId, runId, status, logging` และตรวจ config/DNA ก่อนทำงาน; RUN_LOG payload schema 1.0.0 คงเดิม |
| Chat Runtime | Edge Function v2 มีอยู่ แต่หน้าเว็บยังไม่มีเส้นทางสั่งงาน | deploy Edge v3 ACTIVE; อ่าน source กลับแล้วตรงกับไฟล์ส่งมอบทั้ง 3 ไฟล์ |
| Automatic RUN_LOG | blocked executions ไม่ลง operation_runs; receipt ตรวจเพียงมีแถว | claim/finish ใช้ Run ที่เซิร์ฟเวอร์สร้าง; terminal result และ log commit ใน transaction เดียว; receipt ตรวจ source/owner/turn/payload/parent ตรงกัน |
| Duplicate | มีจุดรับแถวเดิมโดยไม่ตรวจ source/payload ครบ | รับ retry เดิม; ปฏิเสธ content/source conflict และป้องกัน manual/import จอง runId ของ Chat |
| Multi-Agent | ยังไม่มีเส้นทางสั่งงานจริง | เพิ่ม orchestration ถาวร, children 2–3 ตัว, parent/child Run linkage และ exact expected-set gate ก่อน parent success |
| งานค้าง | รอให้มีคน retry จึงตรวจ timeout | เพิ่ม cron `agent-ops-runtime-recovery` ทุกนาที; running เกิน 3 นาที / queued เกิน 10 นาที ถูกปิดด้วย failed log; เห็น cron รัน succeeded จริง |
| หน้าเว็บ | Dashboard V2.3 ไม่มี Chat Runtime | ไฟล์ใหม่มีหน้า Chat, รายชื่อจริง, Multi-Agent, retry Run เดิม, evidence table และตรวจ receipt เทียบแถว Dashboard; ยังไม่ได้ publish |
| AI workspace | ai_enabled=false | เปิดเฉพาะ agent-factory เป็น true แล้ว; คงโควตา 6 turns/นาที และ 50 turns/24 ชั่วโมงต่อผู้ใช้; ยังตรวจ provider credentials ผ่าน authenticated health ไม่ได้ |
| RLS | 17 ตารางเปิด RLS | 18/18 ตารางเปิด RLS; anon เรียก claim ไม่ได้, authenticated เรียก finish/verify ภายในไม่ได้; service_role เรียก finish ได้ |

Agent ที่เรียกผ่าน Runtime นี้ทำงานวิเคราะห์/ร่างข้อความจากข้อมูลที่ส่งและ approved Agent Ops knowledge เท่านั้น การ deploy นี้ไม่ได้ติดตั้งเครื่องมือ SQL, HR, DL Exam, browser หรือ email ให้ Agent และไม่ได้ยืนยันความสามารถเฉพาะทางทุก Skill ใน Registry

## 2. หลักฐานการ deploy

- Migration `agent_ops_production_runtime`: Supabase ตอบ `success=true`.
- ไฟล์ migration: `supabase/migrations/20260921032519_agent_ops_production_runtime.sql`.
- SHA-256 migration: `d4e28a03a1c0dbc99e3b1451bdc7cb421a6943dbae3d459a9ba90b2a4e4dd208`.
- Edge Function: `agent-ops-chat`, version **3**, status **ACTIVE**.
- Edge bundle SHA-256: `1dd223922bf1f7e43f92617349c96319d025777b4323fd293d4bcea7aa677f6c`.
- Source readback: `index.ts`, `core.mjs`, `deno.json` ตรงกับไฟล์ที่ส่งมอบทั้งหมด.
- Cron job ID **8**, schedule `* * * * *`; execution ล่าสุดที่เก็บหลักฐานเวลา 03:37 UTC ได้ `succeeded`.
- GitHub baseline commit: `12f550147cc0e0123907079649a98fa4f555379c`.
- GitHub connection: `pull=true, push=false` จึงไม่ได้ push/merge/publish หน้าเว็บใหม่ และไม่ได้ใช้ช่องทางอื่นข้ามสิทธิ์.

ดู `evidence/deployment-receipt.json` และ `evidence/final-production-state.json` ซึ่งแยกค่าที่อ่านตอน deploy ออกจากสถานะหลังเปิด AI workspace อย่างชัดเจน

## 3. ผลทดสอบที่ผ่านแล้ว — แยกจาก Production Runtime

**Local checks ผ่าน 46/46:**

- SQL integration 22/22: ทดสอบกับ PostgreSQL-compatible PGlite โดยสร้างโครงสร้างจาก baseline ที่อ่านจริง ครอบคลุม RLS, การถอนสิทธิ์, duplicate/conflict, transactional logging, exact orchestration gate และ timeout recovery.
- Edge Runtime 15/15: Auth, /status path, model path, multi-agent, failed command/provider, uncertain commit และ authoritative receipt.
- UI DOM 9/9: ไม่สร้างข้อมูลเมื่อว่าง, viewer สั่งงานไม่ได้, unverified roster, request/turn retry, exact turn↔receipt↔row, multi gate และล้างข้อมูลเมื่อออกจากระบบ.

ชุดทดสอบ local ใช้ fixture/transport แยกในหน่วยความจำ ไม่มี fixture ถูกส่งเข้า Supabase หรือ Dashboard และไม่ถูกนับเป็น Run จริง หลักฐาน: `tests/security-sql-results.json`, `tests/security-review.md`, `evidence/node-tests.txt`. รันซ้ำได้ด้วย `npm ci`, `npm test` และ `npm run test:sql`; SQL harness และ baseline fixtures อยู่ใน `tests/sql/`.

ตรวจ deployment จริงเพิ่มเติม:

- RLS และ function privileges หลัง migration ผ่านตามข้อกำหนดข้างต้น.
- Security Advisor ไม่พบรายการในขอบเขต Agent Operations; 6 รายการที่มีอยู่ในโครงการอยู่นอกขอบเขตนี้และไม่ได้เปลี่ยน.
- เรียก Edge โดยไม่มี session ได้ body `SIGN_IN_REQUIRED`; ไม่เกิด Agent Run. ช่องทางตรวจ HTTP รายงาน transport status 200 จึงไม่นับเป็นหลักฐาน native HTTP 401 หรือ failed-run acceptance; ควรยืนยัน status ผ่าน browser/network หลังเผยแพร่เว็บ.

## 4. หลักฐาน Runtime ที่ผู้ใช้กำหนด

ผลอ่านฐานข้อมูลจริงล่าสุด 03:38 UTC (10:38 น. ไทย): `agent_ops.operation_runs = 0`, Agent unverified = 16. ไม่มี session ผู้ใช้ที่ยืนยันแล้วสำหรับเรียก Runtime ในรอบนี้ และยังไม่ทราบว่า provider endpoint/model/key ฝั่งเซิร์ฟเวอร์พร้อมหรือไม่

| Acceptance case | ผล Production | runId | แถวใน Supabase | Dashboard ตรงกัน |
|---|---|---|---|---|
| `/status` | BLOCKED — ไม่มี authenticated execution | ไม่มี | ไม่มี | ยังไม่ยืนยัน |
| งานวิเคราะห์ 1 งาน | BLOCKED — session/provider ยังไม่ยืนยัน | ไม่มี | ไม่มี | ยังไม่ยืนยัน |
| Multi-Agent 1 งาน | BLOCKED — session/provider ยังไม่ยืนยัน | ไม่มี parent/child runId | ไม่มี | ยังไม่ยืนยัน |
| duplicate runId | BLOCKED — ต้องมี Run จริงต้นฉบับก่อน | ไม่มี | ไม่มี | ยังไม่ยืนยัน |
| failed run | BLOCKED — ยังไม่ได้ส่งคำขอผิดผ่านผู้ใช้จริง | ไม่มี | ไม่มี | ยังไม่ยืนยัน |

`evidence/production-acceptance-pending.json` บันทึกว่า blocked ทั้งหมด ไม่ได้นับผล local หรือการปฏิเสธผู้ไม่เข้าสู่ระบบเป็นการผ่าน 5 กรณีนี้ ไม่มีภาพ Dashboard ที่มี Run จริงสำหรับรับรองในรอบนี้

## 5. การแยกขอบเขต HR / DL Exam

เปรียบเทียบ metadata ก่อน–หลัง: **ตรงกันทั้งหมด** ในขอบเขตที่ตรวจ 209 tables/views, 167 functions, 322 policies, 20 enums และ 4 schemas (`public` ยกเว้น agent_ops API, `private`, `auth`, `storage`).

Fingerprint ก่อนและหลัง: `76196e37800f283b2e3c7299ca583fd4`.

ไม่แก้ HR/DL schema, functions, RLS หรือข้อมูลบุคคล; ไม่เปลี่ยนสมาชิก, password, MFA หรือการตั้งค่า Auth กลาง หลักฐาน `evidence/baseline-isolation.json`, `evidence/post-isolation.json` และ `tests/verify-isolation.sql`.

ขอบเขตการรับรองนี้เป็นการเทียบ definitions/permissions ที่ตรวจ ไม่ใช่การทดสอบทุก workflow ของ HR/DL และไม่อ่านข้อมูล HR/DL ส่วนบุคคลมาใช้ทดสอบ

## 6. ขั้นตอนที่เหลือให้น้อยที่สุด

1. **ผู้มีสิทธิ์ GitHub แทน `index.html` ใน repo เดิม** แล้วรอ GitHub Pages เผยแพร่ — Backend/SQL/cron deploy แล้ว ไม่ต้องรัน migration ซ้ำ.
2. **เข้าสู่ระบบด้วยสมาชิกเดิม แล้วตรวจ Runtime health.** AI workspace เปิดแล้ว; หาก `aiConfigured=false` ให้ตั้งเพียง `AGENT_OPS_AI_ENDPOINT`, `AGENT_OPS_AI_MODEL`, `AGENT_OPS_AI_KEY` ใน Supabase Edge secrets ตามผู้ให้บริการที่อนุมัติ ห้ามส่ง secret ในแชทหรือใส่หน้าเว็บ.
3. **รันทดสอบจริง 5 กรณีและเก็บหลักฐาน.** ใช้ `tests/production-acceptance.mjs` กับ user session จริง หรือทำผ่านหน้าเว็บ จากนั้นตรวจ `runId/agentId/status` ใน evidence table ให้ตรงกับแถวฐานข้อมูลและเก็บภาพ Dashboard. รายละเอียดอยู่ใน `DEPLOYMENT.md`.

การตรวจทุก Agent เป็นรายตัวเพิ่มเติมยังจำเป็นก่อนประกาศว่า “ทุก Agent พร้อมใช้งาน”: แต่ละ Agent ต้องมี successful Runtime receipt และการตรวจคุณภาพงานที่เหมาะกับหน้าที่ การผ่านเพียง /status ไม่ยืนยันความสามารถเฉพาะทาง

**เกณฑ์ปิดงาน:** เผยแพร่เว็บแล้ว, authenticated health/provider ผ่าน, 5 acceptance cases ผ่าน, ทุก receipt มีแถวจริงและ Dashboard แสดงตรงกัน จึงเปลี่ยนผลตัดสินจาก NOT PRODUCTION READY ได้
