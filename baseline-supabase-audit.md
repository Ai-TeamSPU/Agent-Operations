# Supabase Agent Operations baseline audit

Project: `doxunxbgqmybyckczucg`
Audit date: 2026-09-21 UTC
Scope: read-only inspection of `agent_ops`, public `agent_ops_*` RPCs and deployed `agent-ops-chat`.
No records were inserted, updated or deleted. No HR / DL business or personal records were queried.

## Baseline evidence

- Workspace: `agent-factory`, id `b3985efb-cedd-4664-91c5-698bfad95bcf`.
- `collection_status=not_connected`, `learning_mode=draft_only`.
- `ai_enabled=false`, per-user limits 6/minute and 50/day.
- 2 active members, both admins. No membership emails read.
- 16 agents: every agent is `draft`, `unverified`, and lacks implementation attestation.
- All 16 agents have nonempty DNA, logging contract version 1.0.0, `requires_run_log=true`.
- Two orchestrators marked: `factory-orchestrator` and `spu-academic-orchestrator`.
- 11 skills; `chat-response@1.0.0` is active but unverified; other 10 are proposed.
- 70 agent skill mappings, no verified executable registry established.
- `operation_runs=0`, `execution_events=0`, `chat_threads=0`, `chat_turns=0`.
- Historical artifact ledger has 17 rows, explicitly excluded from runtime metrics. Those rows were not read.
- Deployed function `agent-ops-chat` is ACTIVE, version 2; sha256 `60d7d42ed0c8e9fb2845924760a84254c94c8ebd606abc101d2129238add4de4`.
- Edge function JWT gateway verification is false, but handler explicitly requires a bearer token, validates it through Supabase Auth /user, rejects anonymous users, and authorizes workspace membership through RPC.

## Existing flow

1. Authenticated editor/reviewer/admin submits via `agent_ops_submit_chat`.
2. UUID request id is deduplicated by (workspace,user,request_id), differing content raises 23505.
3. Database creates thread/turn UUID run id. One queued/running turn per user enforced by advisory lock.
4. Browser calls Edge execute with turn UUID and authenticated bearer token.
5. Service-only `agent_ops_claim_chat` verifies member/turn ownership, then writes run/skill started events.
6. `/status`, `/skills` use live database data; other prompts use an OpenAI-compatible /chat/completions endpoint.
7. Service-only `agent_ops_finish_chat` updates turn, writes terminal events and inserts completed RUN_LOG into operation_runs in one transaction.
8. Dashboard operations snapshot reads production operation_runs; it currently includes runtime, manual and import sources separately tagged.

No service-only HTTP invoke route is available. The Edge function requires a real user session even though claim/finish use a server-side service credential internally. Database calls that impersonate auth.uid are not evidence of real authenticated runtime.

## Confirmed gaps to fix

1. **No runtime proof**: all execution tables are empty, AI switch off, all agents unverified. DNA text does not establish runtime compliance.
2. **Multi-agent orchestration absent**: deployed runtime only handles one claimed turn and does not call the orchestrator gate.
3. **Weak orchestrator gate**:
   - accepts empty paired arrays as complete;
   - does not reject duplicate child run ids/agents;
   - only matches agent id and existing production row;
   - does not require runtime source or success;
   - lacks parent linkage and explicit logging acknowledgment input.
   - requires auth.uid membership even when service_role has EXECUTE.
4. **Weak finish deduplication**: finish_chat uses ON CONFLICT DO NOTHING, then reports logged based on row existence only. Existing row with different payload/agent/source can be mistaken for the correct receipt.
5. **Blocked turns missing central log**: AGENT_DISABLED / AI_NOT_CONFIGURED / AI_NOT_ENABLED set blocked directly and return without operation_runs record.
6. **Failure response missing receipt**: Edge catch logs through finish_chat but discards returned runId/status/logging, returning error+turnId only.
7. **Potential stale running turn**: timeout resolution happens only when claim is retried; no verified background recovery.
8. **Shared logger split**: operations_write has content-safe deduplication, but finish_chat bypasses it with a direct insert.
9. **Runtime payload identity not linked**: operation_runs guard checks payload.runId equals row run_id and validates shape, but lacks registry existence or turn linkage. Table only has workspace FK.
10. **DNA insertion only**: default contract trigger runs BEFORE INSERT only; supplied custom DNA is retained without adding contract text. Existing 16 have contract, but future custom additions need verification.
11. **Dashboard empty registry**: operations_snapshot filters to active implementation-attested agents/skills; currently returns none. Do not flip draft agents active as proof.
12. **Multi-source metrics risk**: operations_snapshot includes manual/import production rows. Runtime proof views should filter `source_kind=runtime` and preserve separate source provenance.

## Existing RUN_LOG contract

Required exact fields:
`runId, agentId, startedAt, status, trigger, parentAgentId, steps`

Statuses: success / failed / escalated / abandoned.
Triggers: user / schedule / agent.
Each step: stage, skillId, durationSec, waitSec, status, retries.
Stages: intake / routing / retrieval / execution / validation / approval / delivery.
Step status: ok / fail / retry.
Schema rejects extra fields, demo identifiers, invalid ISO timestamps, future time >5 minutes, bad numeric measurements; max 100 steps, 256 KiB payload.
Append-only update/delete trigger is enabled.
Primary key: (workspace_id, environment, run_id).

`agent_ops_operations_write`:
- Runtime writes limited to postgres/service_role.
- Authenticated editor/admin only manual/import in production.
- Same runId+same JSON payload deduplicates; differing payload raises 23505.
- Uses workspace/environment advisory lock.
- Limits 200 runs/2 MiB per request.
- Does not compare source metadata in duplicate path.

## RLS / permissions baseline

- All 17 agent_ops tables have RLS enabled.
- anon has no agent_ops schema usage and no SELECT or INSERT on scoped tables.
- authenticated has no DELETE on any scoped table.
- Public scoped functions all SECURITY INVOKER and fixed empty search_path.
- All scoped public RPCs explicitly restrict EXECUTE; no PUBLIC/anon grant.
- Runtime claim/finish/event-write RPCs are service_role only.
- operation_runs authenticated INSERT policy allows only manual/import production and requires editor/admin membership and created_by=auth.uid().
- Chat threads/turns use owner + active membership RLS; INSERT uses limited column grants so users cannot set run_id, user_id, status, assistant content, etc.
- Registry mutations require admin role and active membership.
- Runtime AI switch UPDATE only allowed to admin through specific column grants.
- chat_turns service_role has broad UPDATE; isolate all runtime code and avoid arbitrary SQL/RPC input.

Supabase security advisors reported no Agent Operations findings. Existing warnings concern unrelated HR / DL functions, a global extension and Auth leaked-password protection. They were left untouched per scope.

## Saved evidence for implementation

Directory `/workspace/scratch/0fef89e4d2ea/db-audit/` contains:
- Relevant deployed RPC definitions (.sql), including submit, claim, finish, state, gate, operations_write and snapshot.
- Full table schema metadata, exact constraint/index definitions, RLS policies, grants and column grants.
- Registry, contract and runtime setting snapshots.
- Deployed Edge function source in `deployed-agent-ops-chat/`.

Evidence is a baseline, not a Production Ready claim. Runtime acceptance remains blocked until authenticated real calls can be made with the deployed runtime and real model configuration.

