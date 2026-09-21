# Local SQL security integration checks

Run `npm ci` then `npm run test:sql` from the repository root. Requires Node.js 20+ and pinned `@electric-sql/pglite` 0.3.14. The install step downloads dependencies; the test itself performs no network calls and has no configuration path for a remote database.

The suite starts a fresh **in-memory** PostgreSQL-compatible database, reconstructs the inspected Agent Operations baseline, applies the repository migration, and tests local fixtures under PostgreSQL roles/RLS. Nothing is written to Supabase, HR, DL Exam, the Dashboard, or any external service. It does not read environment credentials.

Output: `tests/security-sql-results.json`, explicitly marked `LOCAL_SQL_INTEGRATION_NOT_PRODUCTION_EVIDENCE`, including the exact migration SHA-256. Test assertion failures set a nonzero process exit code.

Fixtures contain only Agent Ops schema/constraint/policy/grant metadata, relevant function definitions and the shared text logging contract from the 2026-09-21 read-only audit. They do not contain real users, memberships, chat content, operation rows or HR/DL records. The metadata row counts are historical baseline facts, not seeded records. Test users, agents and turns are created in process memory only.

`auth.uid()` reads a local PostgreSQL setting for role tests; it does not authenticate a real user. `cron.schedule()` is a stub, allowing the exact migration to be evaluated without a scheduler extension; the reaper function is invoked directly in tests. No claim is made about actual cron operation, network races, model execution or browser rendering. Those require the separate production acceptance workflow.

Reconstructed triggers include the actual RUN_LOG guard, execution-event guard, chat insertion guard and default Agent DNA trigger. Unrelated knowledge-review and historical-ledger triggers are outside these test paths.
