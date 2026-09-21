# Independent production security review

Review date: 2026-09-21 UTC. Repository: Ai-TeamSPU/Agent-Operations.

**Code review outcome: no remaining blocking finding in the reviewed migration/runtime/UI changes. This is not production runtime evidence and does not establish Production Ready.** A real approved user session, deployed function, model execution and browser parity still require the production acceptance evidence recorded separately.

## Reviewed artifacts

- `supabase/migrations/20260921032519_agent_ops_production_runtime.sql`
- `supabase/functions/agent-ops-chat/core.mjs`
- Runtime submission, recovery and receipt display in `index.html`
- Live read-only baseline under the review workspace `db-audit/`: schema, constraints/indexes, RLS policies, table/column grants, existing RPCs, RUN_LOG and event guards.

Tested migration SHA-256: `d4e28a03a1c0dbc99e3b1451bdc7cb421a6943dbae3d459a9ba90b2a4e4dd208`.
Local integration test time: 2026-09-21T03:34:19.657Z.

## Verification method and limits

Executed the exact migration against an in-memory PostgreSQL-compatible PGlite 0.3.14 database reconstructed from the inspected baseline table metadata, constraints, RLS policies, table/column grants and relevant live function definitions. Actual RUN_LOG and execution-event guard triggers were included. Local-only fixture users, roles and turns were created in this isolated process. **No local fixture or fake run was uploaded to Supabase or the Dashboard.**

`cron.schedule` was stubbed in the local harness: the reaper function behavior was executed, but the scheduler itself was not simulated as a production pass. The deployed cron job must be inspected live. The local Auth UID function represented a PostgreSQL request identity for RLS tests; it is not proof of real login. No provider/model call or browser render occurred in this SQL harness. It does not prove concurrent interprocess or network behavior. Runtime and UI suites provide separate checks; authenticated production runs remain a distinct gate.

Results: **22/22 local SQL integration assertions passed**. Machine-readable outcome: `tests/security-sql-results.json`. Reproducible local harness and scoped baseline fixtures: `tests/sql/` (`npm run test:sql`).

## Assertions

- PASS — authenticated submission assigns durable turn/run identity
- PASS — identical request deduplicates to same turn
- PASS — conflicting duplicate request rejected
- PASS — claim starts run once
- PASS — finish commits exact runtime row and receipt
- PASS — identical finish deduplicates without extra run row
- PASS — conflicting finish payload rejected
- PASS — anonymous cannot submit or call runtime claim
- PASS — viewer cannot dispatch and authenticated cannot call service verify
- PASS — outsider cannot read private turn or operation rows
- PASS — revoked member cannot replay claim or verify terminal answer
- PASS — missing model configuration produces durable failed run
- PASS — missing logging config key fails closed
- PASS — multi-agent parent waits for two durable child turns
- PASS — multi-agent child receipts link exact root run and agent
- PASS — multi-agent root only succeeds after exact child gate
- PASS — gate rejects empty, duplicate and mismatched agent/run pairs
- PASS — failed child prevents root success and logs failed root
- PASS — running lease timeout commits failed log without re-execution
- PASS — reserved runtime runId blocks forged manual log
- PASS — expired queued request receives explicit QUEUE_TIMEOUT failed receipt
- PASS — revocation recovery logs failure but does not return private answer

## Findings corrected during review

1. **Revoked member receipt replay:** claim and service verification now authorize active membership before terminal receipt return; recovery can still close stale work without returning the root answer.
2. **NULL-sensitive contract validation:** required config values now use fail-closed comparisons; missing contract keys cannot bypass checks. Identity fields include agentId/runId/status/logging.
3. **Multi-agent gate completeness:** completion requires the exact count of unique expected child agents, same owner, parent and orchestration, successful terminal state, and exact persisted runtime receipt.
4. **PL/pgSQL ambiguity:** the child-agent loop variable no longer conflicts with the `agents.code` column. Multi submission was invoked successfully in PostgreSQL rather than merely parsed.
5. **Orphan recovery:** a bounded service-only reaper covers expired running work and expired accepted queued work. Queue timeout is explicitly failed intake handling with measured queue time; it is not counted as successful AI work.
6. **Provider account check:** Edge Auth/user validation requires a nonanonymous confirmed account, matching the browser's login policy.
7. **Reserved runtime IDs/provenance:** direct manual/import rows cannot reserve a chat run ID or forge chat runtime links; successful receipt requires exact source, turn, owner, payload and parent linkage.

## Access and isolation assessment

- All new table access uses owner plus active workspace membership. Existing RLS remains enabled.
- Runtime claim, finish, verify and recovery RPCs are unavailable to authenticated/anonymous browser roles. Helpers remain invoker-rights with a fixed search path.
- No service credential is present in frontend code. The Edge endpoint validates the real Auth user and accepts only a fixed operation/turn request shape.
- Model calls receive role/context data only. There is no arbitrary RPC, SQL, HR/DL reader, browser, file executor or model tool dispatch. Returned model tool calls are rejected.
- The migration is limited to `agent_ops`, `public.agent_ops_*`, and its own named cron job. It does not alter HR or DL tables, project Auth configuration or membership.
- UI success requires the database receipt and a fresh dashboard row to agree on run ID, agent ID, successful state and runtime source. Multi-agent success also requires all child receipts and the orchestrator gate. Message and agent fields are escaped for HTML display.
- Draft registry entries remain explicitly unverified. Code deployment and local passing tests are not represented as agent runtime readiness.

## Required production evidence still separate

Verify the deployed function revision, migration/ACL state and enabled named recovery job; execute /status, one model analysis, one multi-agent task, identical and conflicting duplicate requests, and a genuine failing request with a real member session. For each terminal run, retain its receipt and persisted `agent_ops.operation_runs` row, then show matching IDs in the authenticated Dashboard. A missing model secret, login session, successful run or browser evidence must remain blocked rather than be filled with fabricated data.
