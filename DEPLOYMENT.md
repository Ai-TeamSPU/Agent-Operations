# Agent Operations: deployment and acceptance

Target: Supabase `doxunxbgqmybyckczucg`, GitHub `Ai-TeamSPU/Agent-Operations`.

**The production readiness report is the authority for what has actually been deployed and tested.** Source code, a deployment receipt, and local tests do not establish successful production execution.

## Scope

This release adds authenticated chat execution and bounded multi-agent collaboration to the existing page. Agents draft or analyze the supplied content using the configured model. They do not gain SQL, HR, DL Exam, browsing, email, or other external-action tools. Existing registry labels remain unverified until independently supported by real evidence.

Database changes are limited to `agent_ops` and its `public.agent_ops_*` API functions. Do not run the older `enable-workspace-admin.sql` as part of this release. Do not change shared Auth configuration, MFA, HR roles, or DL Exam tables.

## Deployment

Skip each step that the production readiness report identifies as already deployed.

1. Apply only `supabase/migrations/20260921032519_agent_ops_production_runtime.sql` in the target project's SQL Editor. Do not push unrelated migrations from this shared project.
2. Deploy only `agent-ops-chat`, with the source under `supabase/functions/agent-ops-chat`. Its handler validates the bearer session against Supabase Auth and checks workspace membership. Keep the per-function setting in `supabase/config.toml`; do not change settings for other functions.
3. Replace the repository-root `index.html` with this release's file. Keep the existing GitHub Pages source and access settings. Wait for Pages publication, then hard refresh. The page must show the new runtime section.

If the AI connection is not already configured, set these **server-side Edge Function secrets** in the target Supabase project:

| Variable | Value |
| --- | --- |
| `AGENT_OPS_AI_ENDPOINT` | Approved HTTPS chat-completions endpoint |
| `AGENT_OPS_AI_MODEL` | Model ID supported by that endpoint |
| `AGENT_OPS_AI_KEY` | Existing authorized API key for that provider |
| `AGENT_OPS_ALLOWED_ORIGINS` | `https://ai-teamspu.github.io` for the production page |

Never put an AI key, service key, or user token in `index.html`, GitHub, chat, screenshots, or an evidence archive. Built-in Supabase server credentials remain server-side.

This rollout already enabled AI for agent-factory. If a later emergency stop disables it, re-enable only this workspace after configuring the provider:

```sql
update agent_ops.runtime_settings s
set ai_enabled = true
from agent_ops.workspaces w
where s.workspace_id = w.id and w.slug = 'agent-factory';
```

The authenticated Runtime health response must report both `aiConfigured=true` and `aiEnabled=true`. A successful `/status` alone does not verify the model provider.

## Required acceptance

Sign in through the existing page with an active Agent Operations editor/admin/reviewer account. Do not reset credentials or grant memberships solely for a test.

Run the supplied `tests/production-acceptance.mjs` in a trusted local environment with an existing user access token supplied through `AGENT_OPS_ACCESS_TOKEN` and the public key through `AGENT_OPS_PUBLISHABLE_KEY` (see `.env.example`). The script never prints the token; it records observed receipts and snapshot rows. Read the script before running it. It submits real, clearly described acceptance tasks and respects the current request limits.

The five required cases are `/status`, one analysis based on current Registry evidence, one multi-agent analysis, retry of the exact same request/run, and an unsupported command producing a logged failure. Provider/configuration errors are failures or blockers, never substituted by generated sample output.

Run with `node tests/production-acceptance.mjs` from the repository directory after setting those variables securely. Then inspect the web Dashboard. For each receipt, the same `runId`, `agentId`, outcome, and Runtime source must appear in its live evidence table. Multi-agent completion also requires the server gate and all expected child receipts. Save the evidence export and an authenticated Dashboard screenshot that shows these IDs. A JSON comparison alone does not prove that the browser rendered the rows.

For a stuck request, use the existing turn's refresh/retry action. Do not generate a replacement request ID until the original state is resolved. Run recovery is deliberately idempotent.

## Rollback and limits

Keep the prior `index.html` and Edge Function source from the deployment baseline. If activation fails, disable AI for this workspace and restore those two source versions. Do not delete operation logs or drop newly added linkage columns; retained evidence remains available for diagnosis. Restoring the old SQL gate would reintroduce the logging weaknesses, so a database rollback needs review rather than an automatic destructive script.

Read-only structural fingerprints in `tests/verify-isolation.sql` can compare non-Agent database objects before and after deployment. Matching fingerprints establish that the inspected schema/function/policy definitions did not change; they are not a full functional test of HR or DL Exam.
