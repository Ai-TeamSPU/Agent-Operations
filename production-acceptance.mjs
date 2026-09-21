#!/usr/bin/env node
/**
 * Real production acceptance only. Node.js >=20; no packages required.
 * Required env: AGENT_OPS_PUBLISHABLE_KEY, AGENT_OPS_ACCESS_TOKEN (real member JWT).
 * Optional env: AGENT_OPS_AGENT_CODE, AGENT_OPS_ORCHESTRATOR_CODE,
 *   AGENT_OPS_CHILD_AGENT_CODES (comma-separated 2-3 ids from live registry),
 *   AGENT_OPS_EVIDENCE_PATH.
 *
 * This program submits real tasks through the same authenticated RPC/Edge route
 * as the web UI. It never fabricates RUN_LOG rows, inserts data directly, creates
 * users, changes membership, enables AI, or uses a service-role credential.
 * Model analysis and multi-agent tasks incur the configured runtime's normal cost.
 */
import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';

const BASE = 'https://doxunxbgqmybyckczucg.supabase.co';
const WORKSPACE = 'agent-factory';
const key = process.env.AGENT_OPS_PUBLISHABLE_KEY || '';
const token = process.env.AGENT_OPS_ACCESS_TOKEN || '';
const evidencePath = resolve(process.env.AGENT_OPS_EVIDENCE_PATH || 'evidence/production-acceptance.json');
const sleep = ms => new Promise(done => setTimeout(done, ms));
const hash = value => createHash('sha256').update(value).digest('hex');
const evidence = {
  formatVersion: 1, projectRef: 'doxunxbgqmybyckczucg', workspace: WORKSPACE,
  startedAt: new Date().toISOString(), mode: 'real_authenticated_runtime',
  syntheticDataCreated: false, directLogWrites: false, checks: [],
  dashboardRenderedParity: { status: 'pending', reason: 'A browser check or screenshot of these run IDs is required; this CLI verifies the same dashboard RPC data source only.' },
};
const check = (name, status, details = {}) => {
  evidence.checks.push({ name, status, ...details });
  process.stdout.write(name + ': ' + status + '\n');
};
function requireCondition(value, code) {
  if (!value) { const error = new Error(code); error.code = code; throw error; }
}
function jwtRole(value) {
  try { return JSON.parse(Buffer.from(value.split('.')[1], 'base64url')).role; } catch { return null; }
}
function sanitizedError(error) {
  return { code: String(error?.code || error?.name || 'REQUEST_FAILED').replace(/[^A-Za-z0-9_.:-]/g, '_').slice(0, 100), httpStatus: error?.httpStatus || null };
}
async function request(path, body, timeoutMs = 15000) {
  const response = await fetch(BASE + path, {
    method: body === undefined ? 'GET' : 'POST', redirect: 'error',
    headers: { apikey: key, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const value = await response.json().catch(() => ({}));
  return { httpStatus: response.status, body: value };
}
async function rpc(name, args) {
  const result = await request('/rest/v1/rpc/' + name, args);
  if (result.httpStatus >= 400) {
    const error = new Error('RPC_FAILED'); error.code = result.body.code || 'RPC_FAILED'; error.httpStatus = result.httpStatus; throw error;
  }
  return result.body;
}
async function edge(body) { return request('/functions/v1/agent-ops-chat', body, 175000); }
async function snapshot() {
  const value = await rpc('agent_ops_operations_snapshot', { p_workspace_slug: WORKSPACE });
  requireCondition(value.scope?.truncated !== true && Array.isArray(value.runs), 'SNAPSHOT_INCOMPLETE');
  return value;
}
const runCode = item => item?.id || item?.code || item?.agent_code;
const disabled = item => item?.lifecycle === 'deprecated' || item?.runtime_status === 'disabled' || item?.runtimeStatus === 'disabled';
const isOrchestrator = item => item?.isOrchestrator === true || item?.is_orchestrator === true;

function receiptOnly(receipt) {
  const fields = ['id','turnId','agentId','runId','status','logging','errorCode','model','executionMode','claimed','deduplicated'];
  const output = Object.fromEntries(fields.filter(k => receipt?.[k] !== undefined).map(k => [k, receipt[k]]));
  if (receipt?.answer) output.answerSha256 = hash(String(receipt.answer));
  if (receipt?.storedTurn) output.storedTurn = receipt.storedTurn;
  if (receipt?.gate) output.gate = {
    ...receipt.gate,
    ...(Array.isArray(receipt.gate.children) ? { children: receipt.gate.children.map(receiptOnly) } : {}),
  };
  if (Array.isArray(receipt?.children)) output.children = receipt.children.map(receiptOnly);
  return output;
}
function rowEvidence(row) {
  const data = row.data || row.payload || {};
  return {
    runId: data.runId || row.id || row.run_id,
    agentId: data.agentId, status: data.status, parentAgentId: data.parentAgentId,
    sourceKind: data._source?.kind || row.source_kind,
    sourceId: data._source?.id || row.source_id,
    startedAt: data.startedAt, receivedAt: data._source?.createdAt || row.received_at,
    payloadSha256: hash(JSON.stringify(Object.fromEntries(Object.entries(data).filter(([key]) => key !== '_source')))),
  };
}
function verifyReceipt(receipt, report, expectedStatus = 'succeeded', expectedAgent) {
  requireCondition(receipt?.runId && receipt?.agentId, 'MISSING_RECEIPT_IDENTITY');
  requireCondition(receipt.logging === 'logged', 'RUN_LOG_NOT_ACKNOWLEDGED');
  requireCondition(receipt.status === expectedStatus, 'UNEXPECTED_TERMINAL_STATUS');
  if (expectedAgent) requireCondition(receipt.agentId === expectedAgent, 'AGENT_RECEIPT_MISMATCH');
  const rows = report.runs.filter(row => (row.data?.runId || row.id) === receipt.runId);
  requireCondition(rows.length === 1, 'RUN_ROW_COUNT_MISMATCH');
  const row = rowEvidence(rows[0]);
  requireCondition(row.agentId === receipt.agentId, 'AGENT_ROW_MISMATCH');
  requireCondition(row.sourceKind === 'runtime', 'ROW_IS_NOT_RUNTIME');
  requireCondition(row.status === (expectedStatus === 'succeeded' ? 'success' : 'failed'), 'ROW_STATUS_MISMATCH');
  return row;
}
async function submitSingle(agentCode, message, requestId = randomUUID()) {
  const args = { p_workspace_slug: WORKSPACE, p_agent_code: agentCode, p_thread_id: null, p_request_id: requestId, p_message: message };
  const submitted = await rpc('agent_ops_submit_chat', args);
  return { args, submitted, turnId: submitted.id || submitted.turnId };
}
async function executeTurn(turnId, threadId) {
  requireCondition(turnId, 'SUBMIT_DID_NOT_RETURN_TURN');
  let response;
  try { response = await edge({ operation: 'execute', turnId }); }
  catch (error) { response = { httpStatus: 0, body: { errorCode: sanitizedError(error).code } }; }
  let receipt = response.body;
  // Never resubmit or create a replacement request after an uncertain commit.
  // A repeat execute claims the same turn and must return its durable receipt.
  const until = Date.now() + 65000;
  while ((!receipt?.runId || !['succeeded','failed','blocked'].includes(receipt.status)) && Date.now() < until) {
    if (response.httpStatus === 401 || response.httpStatus === 403) break;
    if (receipt?.errorCode === 'UNSUPPORTED_OPERATION') break;
    await sleep(2500);
    if (threadId) {
      const state = await rpc('agent_ops_chat_state', { p_workspace_slug: WORKSPACE, p_thread_id: threadId });
      const turn = state.turns?.find(item => item.id === turnId);
      // Running workers retain their lease. A queued root can be waiting for
      // children after an interrupted request: execute the SAME durable turn.
      if (turn?.status === 'running') continue;
    }
    response = await edge({ operation: 'execute', turnId });
    receipt = response.body;
  }
  let storedTurn;
  if (threadId) {
    const state = await rpc('agent_ops_chat_state', { p_workspace_slug: WORKSPACE, p_thread_id: threadId });
    const turn = state.turns?.find(item => item.id === turnId);
    if (turn) {
      storedTurn = { id:turn.id, runId:turn.run_id, status:turn.status, model:turn.model, executionMode:turn.execution_mode };
      if (receipt?.runId) requireCondition(turn.run_id === receipt.runId, 'STORED_TURN_RUN_ID_MISMATCH');
      if (turn.receipt?.logging) {
        storedTurn.logging = turn.receipt.logging;
        requireCondition(turn.receipt.runId === receipt.runId && turn.receipt.logging === receipt.logging, 'STORED_RECEIPT_MISMATCH');
      }
    }
  }
  return { ...receipt, httpStatus: response.httpStatus, storedTurn };
}
async function scenario(name, work) {
  try { const details = await work(); check(name, 'passed', details); return details; }
  catch (error) { check(name, 'failed', sanitizedError(error)); return null; }
}
async function main() {
  if (!key || !token) {
    check('authenticated_runtime_access', 'blocked', { reason: 'Set AGENT_OPS_PUBLISHABLE_KEY and AGENT_OPS_ACCESS_TOKEN using an active approved member session. No runtime request was sent.' });
    for (const name of ['status_command','analysis','multi_agent','duplicate_run_id','conflicting_duplicate_request','failed_run','dashboard_data_parity']) check(name, 'blocked', { reason: 'Authenticated runtime access unavailable.' });
    return;
  }
  requireCondition(!key.startsWith('sb_secret_') && jwtRole(key) !== 'service_role' && jwtRole(token) === 'authenticated', 'USER_SESSION_AND_PUBLIC_KEY_REQUIRED');
  const user = await request('/auth/v1/user');
  requireCondition(user.httpStatus === 200 && user.body.id && !user.body.is_anonymous, 'INVALID_USER_SESSION');
  const healthResult = await edge({ operation: 'health', workspace: WORKSPACE });
  requireCondition(healthResult.httpStatus === 200 && healthResult.body.ok === true, 'RUNTIME_HEALTH_FAILED');
  const health = healthResult.body;
  evidence.runtime = Object.fromEntries(['version','role','aiConfigured','aiEnabled','mode','tools','runLogging','multiAgent','unsupportedCommandFailure','capabilities'].filter(k => health[k] !== undefined).map(k => [k, health[k]]));
  check('authenticated_runtime_access', 'passed', { runtimeVersion: health.version, memberRole: health.role });

  const state = await rpc('agent_ops_chat_state', { p_workspace_slug: WORKSPACE, p_thread_id: null });
  requireCondition(!state.pending, 'EXISTING_PENDING_TURN_REQUIRES_RESOLUTION');
  let liveRegistry = state.registry || (Array.isArray(state.agents) ? { agents:state.agents, skills:state.skills } : null);
  if (!liveRegistry?.agents?.length) {
    const dashboard = await rpc('agent_ops_dashboard', { p_workspace_slug: WORKSPACE, p_days: 30 });
    liveRegistry = dashboard.registry;
  }
  const agents = (liveRegistry?.agents || state.agents || []).filter(item => !disabled(item));
  requireCondition(agents.length > 0, 'LIVE_REGISTRY_EMPTY');
  const configuredAgent = process.env.AGENT_OPS_AGENT_CODE;
  const chosen = configuredAgent ? agents.find(item => runCode(item) === configuredAgent) : agents.find(item => runCode(item) === 'factory-builder') || agents.find(item => !isOrchestrator(item)) || agents[0];
  requireCondition(chosen, 'AGENT_NOT_IN_LIVE_REGISTRY');
  const agentCode = runCode(chosen);
  const before = await snapshot();
  evidence.before = { generatedAt: before.generatedAt, operationRunCount: before.runs.length, coverage: before.coverage };
  evidence.registryObserved = { agents: agents.length, skills: liveRegistry?.skills?.length ?? null };

  let statusSubmission;
  const statusTest = await scenario('status_command', async () => {
    statusSubmission = await submitSingle(agentCode, '/status');
    const receipt = await executeTurn(statusSubmission.turnId, statusSubmission.submitted.threadId);
    const row = verifyReceipt(receipt, await snapshot(), 'succeeded', agentCode);
    return { receipt: receiptOnly(receipt), row, dashboardDataParity: true };
  });

  if (statusTest) {
    await scenario('duplicate_run_id', async () => {
      const repeated = await rpc('agent_ops_submit_chat', statusSubmission.args);
      requireCondition((repeated.id || repeated.turnId) === statusSubmission.turnId && repeated.deduplicated === true, 'REQUEST_NOT_DEDUPLICATED');
      const receipt = await executeTurn(statusSubmission.turnId, statusSubmission.submitted.threadId);
      requireCondition(receipt.runId === statusTest.receipt.runId, 'DUPLICATE_CREATED_NEW_RUN_ID');
      const row = verifyReceipt(receipt, await snapshot(), 'succeeded', agentCode);
      return { receipt: receiptOnly(receipt), row, centralRowsForRunId: 1, method: 'Replay the identical request and the same runtime turn; verify the original runId appears once.' };
    });
    await scenario('conflicting_duplicate_request', async () => {
      let rejected;
      try { await rpc('agent_ops_submit_chat', { ...statusSubmission.args, p_message: '/skills' }); }
      catch (error) { rejected = error; }
      requireCondition(rejected && (rejected.code === '23505' || rejected.httpStatus === 409), 'CONFLICTING_REQUEST_WAS_NOT_REJECTED');
      return { runId: statusTest.receipt.runId, rejectionCode: rejected.code, httpStatus: rejected.httpStatus };
    });
  } else {
    check('duplicate_run_id','blocked',{ reason:'No successful original runtime receipt to replay.' });
    check('conflicting_duplicate_request','blocked',{ reason:'No successful original runtime submission to replay.' });
  }

  if (health.aiConfigured === true && health.aiEnabled === true) {
    await scenario('analysis', async () => {
      const fresh = await snapshot();
      const facts = { registeredAgents: agents.length, registeredSkills: liveRegistry?.skills?.length ?? null, runtimeRuns: fresh.coverage?.runtimeRuns ?? fresh.runs.filter(r => r.data?._source?.kind === 'runtime').length, unverifiedAgents: fresh.coverage?.excludedUnverifiedAgents ?? null };
      const message = 'Analyze this real Agent Operations readiness snapshot. Separate verified facts, risks, and three prioritized actions. Do not invent executions or infer agent readiness from registry membership. Facts just read from this production workspace: ' + JSON.stringify(facts);
      const submission = await submitSingle(agentCode, message);
      const receipt = await executeTurn(submission.turnId, submission.submitted.threadId);
      const row = verifyReceipt(receipt, await snapshot(), 'succeeded', agentCode);
      requireCondition(typeof receipt.answer === 'string' && receipt.answer.trim().length > 0, 'MISSING_ANALYSIS_RESULT');
      return { inputFacts: facts, receipt: receiptOnly(receipt), row, dashboardDataParity: true };
    });

    await scenario('multi_agent', async () => {
      const configuredOrchestrator = process.env.AGENT_OPS_ORCHESTRATOR_CODE;
      const orchestrator = configuredOrchestrator ? agents.find(a => runCode(a) === configuredOrchestrator) : agents.find(isOrchestrator);
      requireCondition(orchestrator && isOrchestrator(orchestrator), 'ORCHESTRATOR_NOT_IN_LIVE_REGISTRY');
      const requestedChildren = process.env.AGENT_OPS_CHILD_AGENT_CODES?.split(',').map(x => x.trim()).filter(Boolean);
      const preferredChildren = ['factory-builder','HR-REQ-001','wcag-audit'].filter(code => agents.some(a => runCode(a) === code && !isOrchestrator(a)));
      const children = requestedChildren || [...new Set([...preferredChildren,...agents.filter(a => !isOrchestrator(a)).map(runCode)])].slice(0,2);
      requireCondition(children.length >= 2 && children.length <= 3 && new Set(children).size === children.length && children.every(code => agents.some(a => runCode(a) === code)) && !children.includes(runCode(orchestrator)), 'LIVE_CHILD_AGENT_SELECTION_INVALID');
      const realFindings = evidence.checks.map(item => ({ check:item.name, result:item.status, runId:item.receipt?.runId || null }));
      const message = 'Collaborate to assess Agent Operations production readiness from these real acceptance findings. Each participant evaluates the evidence within its stated role; the orchestrator reconciles findings and states remaining limits. Do not claim business system integrations or executions that these receipts do not prove. Observed findings: ' + JSON.stringify(realFindings);
      const submitted = await rpc('agent_ops_submit_orchestration', { p_workspace_slug: WORKSPACE, p_orchestrator_code: runCode(orchestrator), p_agent_codes: children, p_request_id: randomUUID(), p_message: message });
      const receipt = await executeTurn(submitted.parentTurnId || submitted.id || submitted.turnId, submitted.threadId);
      const report = await snapshot();
      const parentRow = verifyReceipt(receipt, report, 'succeeded', runCode(orchestrator));
      requireCondition(receipt.gate?.complete === true && Array.isArray(receipt.children) && receipt.children.length === children.length, 'ORCHESTRATOR_GATE_NOT_VERIFIED');
      requireCondition(new Set(receipt.children.map(c => c.runId)).size === children.length, 'DUPLICATE_CHILD_RUN_ID');
      const childRows = children.map(code => {
        const child = receipt.children.find(item => item.agentId === code);
        const row = verifyReceipt(child, report, 'succeeded', code);
        requireCondition(row.parentAgentId === runCode(orchestrator), 'CHILD_PARENT_MISMATCH');
        return row;
      });
      return { receipt: receiptOnly(receipt), parentRow, childRows, dashboardDataParity: true };
    });
  } else {
    check('analysis', 'blocked', { reason: 'The live health response reports AI not configured or not enabled.' });
    check('multi_agent', 'blocked', { reason: 'The live health response reports AI not configured or not enabled.' });
  }

  const supportedFailure = health.unsupportedCommandFailure === true || health.capabilities?.unsupportedCommandFailure === true;
  if (supportedFailure) {
    await scenario('failed_run', async () => {
      const submission = await submitSingle(agentCode, '/agent-ops-unsupported-command');
      const receipt = await executeTurn(submission.turnId, submission.submitted.threadId);
      requireCondition(receipt.errorCode === 'UNSUPPORTED_COMMAND', 'UNEXPECTED_FAILURE_REASON');
      const row = verifyReceipt(receipt, await snapshot(), 'failed', agentCode);
      return { receipt: receiptOnly(receipt), row, failureCause: 'An actual unsupported command rejected by the deployed runtime.', dashboardDataParity: true };
    });
  } else check('failed_run', 'blocked', { reason: 'This deployed runtime does not advertise deterministic unsupported-command failure; no artificial failure row was written.' });

  const after = await snapshot();
  evidence.after = { generatedAt: after.generatedAt, operationRunCount: after.runs.length, coverage: after.coverage };
  const proven = evidence.checks.filter(item => item.dashboardDataParity === true);
  check('dashboard_data_parity', proven.length > 0 ? 'passed' : 'blocked', { verifiedScenarioCount: proven.length, source: 'public.agent_ops_operations_snapshot -> agent_ops.operation_runs', note: 'RPC data parity; rendered browser parity remains separate.' });
}

try { await main(); }
catch (error) { check('acceptance_execution', 'blocked', sanitizedError(error)); }
finally {
  evidence.completedAt = new Date().toISOString();
  evidence.allRuntimeChecksPassed = ['status_command','analysis','multi_agent','duplicate_run_id','conflicting_duplicate_request','failed_run','dashboard_data_parity'].every(name => evidence.checks.some(item => item.name === name && item.status === 'passed'));
  evidence.productionReady = false; // Requires the separate RLS/isolation and rendered UI gates.
  evidence.result = evidence.allRuntimeChecksPassed ? 'runtime_passed_remaining_gates_required' : 'not_production_ready';
  await mkdir(dirname(evidencePath), { recursive:true });
  await writeFile(evidencePath, JSON.stringify(evidence, null, 2) + '\n', { mode:0o600 });
  process.stdout.write('Evidence: ' + evidencePath + '\n');
  process.exitCode = evidence.allRuntimeChecksPassed ? 0 : 2;
}
