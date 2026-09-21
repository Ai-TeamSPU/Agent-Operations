# Agent Operations

Authenticated Agent chat, bounded multi-agent collaboration, and an evidence-based operations Dashboard for the existing `agent-factory` workspace.

**Read `PRODUCTION_READINESS_REPORT.md` for the actual deployment and acceptance status.** Do not interpret source code, draft Registry entries, historical test reports, or local unit tests as proof of successful production execution.

## Runtime path

The user signs in through Supabase Auth. The page submits a stable request ID through an authorized Agent Ops RPC, receives a server-generated turn/run ID, and invokes `agent-ops-chat`. The worker claims the turn once, executes the requested operation, and commits its terminal result and central `RUN_LOG` together. The page reads the same `agent_ops.operation_runs` rows back before displaying completion evidence.

For multi-agent work, the database stores the expected participants and parent/child relationships. The worker runs the children and checks their authoritative receipts. The Orchestrator's successful completion requires every expected agent/run pair to be a successful Runtime record from that same orchestration. Merely returning the text `logging=logged` is insufficient.

## Honest capability boundary

- `/status` and `/skills` read Agent Operations data.
- Model tasks analyze or draft from provided content and approved Agent Ops knowledge.
- Agent DNA and the shared logging contract are loaded for each claim.
- The model cannot execute SQL, read HR/DL records, browse, send emails, or modify other systems.
- Registry status remains truthful. A draft/unverified agent can be exercised without being declared production-ready.
- No synthetic runs, seeded history, or fallback model output populate the Dashboard.

## Authentication and data

Normal login validates the existing user with Supabase Auth, then enforces active workspace membership. This release does not create users, grant memberships, change passwords/MFA, or modify shared Auth settings. Existing account recovery protections remain in place. Sessions stay in browser memory; the frontend contains only the public publishable key.

`RUN_LOG` stores structured telemetry, not raw prompts or answers. Authenticated chat history contains the user's submitted content and returned answer under its existing owner RLS. Do not submit secrets or unnecessary personal data.

## Files

- `index.html`: self-contained GitHub Pages frontend and runtime controls.
- `supabase/functions/agent-ops-chat/`: authenticated worker source.
- `supabase/migrations/20260921032519_agent_ops_production_runtime.sql`: isolated database hardening and orchestration linkage.
- `RUN_LOG.schema.json`: unchanged shared payload version 1.0.0.
- `tests/`: local regression checks, real acceptance runner, and isolation verification.
- `DEPLOYMENT.md`: remaining activation steps and acceptance procedure.
- `evidence/`: explicitly labeled observations, never sample production runs.

The existing `test-report.json`, `verification-receipt.json`, and `test_real_only.py` belong to earlier releases. They are historical artifacts and are not the acceptance evidence for this release.
