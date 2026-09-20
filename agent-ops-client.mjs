/**
 * Agent Operations server integration. Importing this module does not run a task,
 * create an Agent, generate measurements, or contact Supabase.
 * Supply real RUN_LOG records only. Credentials must remain on a trusted server.
 */
const RUN_FIELDS = ['runId','agentId','startedAt','status','trigger','parentAgentId','steps'];
const STEP_FIELDS = ['stage','skillId','durationSec','waitSec','status','retries'];
const STAGES = ['intake','routing','retrieval','execution','validation','approval','delivery'];
const ID = /^(?!demo-)[A-Za-z0-9_.:-]{1,128}$/;
function assert(condition, message) { if (!condition) throw new TypeError(message); }
function exactFields(value, fields, name) {
  assert(value && typeof value === 'object' && !Array.isArray(value), `${name} must be an object`);
  assert(fields.every(k => Object.hasOwn(value,k)) && Object.keys(value).every(k => fields.includes(k)), `${name}: missing or extra fields`);
}
export function validateRunLog(run) {
  exactFields(run, RUN_FIELDS, 'RUN_LOG');
  for (const key of ['runId','agentId']) assert(typeof run[key] === 'string' && ID.test(run[key]), `Invalid ${key}`);
  assert(run.parentAgentId === null || (typeof run.parentAgentId === 'string' && ID.test(run.parentAgentId)), 'Invalid parentAgentId');
  assert(typeof run.startedAt === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$/.test(run.startedAt), 'startedAt requires ISO 8601 with timezone');
  const started = Date.parse(run.startedAt);
  assert(Number.isFinite(started) && started <= Date.now()+300000, 'Invalid or future startedAt');
  const [year, month, day] = run.startedAt.slice(0,10).split('-').map(Number);
  assert(month >= 1 && month <= 12 && day >= 1 && day <= new Date(Date.UTC(year,month,0)).getUTCDate(), 'Impossible calendar date');
  assert(['success','failed','escalated','abandoned'].includes(run.status), 'Invalid status');
  assert(['user','schedule','agent'].includes(run.trigger), 'Invalid trigger');
  assert(Array.isArray(run.steps) && run.steps.length <= 100, 'Maximum 100 observed steps');
  for (const step of run.steps) {
    exactFields(step, STEP_FIELDS, 'step');
    assert(STAGES.includes(step.stage), 'Invalid stage');
    assert(step.skillId === null || (typeof step.skillId === 'string' && ID.test(step.skillId)), 'Invalid skillId');
    assert(['ok','fail','retry'].includes(step.status), 'Invalid step status');
    for (const key of ['durationSec','waitSec','retries']) assert(typeof step[key] === 'number' && Number.isFinite(step[key]) && step[key] >= 0 && step[key] <= 31536000, `${key} must be a measured, nonnegative number`);
    assert(Number.isInteger(step.retries) && step.retries <= 10000 && (step.status !== 'retry' || step.retries > 0), 'Invalid retry count');
  }
  assert(new TextEncoder().encode(JSON.stringify(run)).length <= 262144, 'RUN_LOG is larger than 256 KiB');
  return run;
}
export class AgentOperationsClient {
  /** @param {{url:string,apiKey:string,accessToken:string,workspace?:string,fetchImpl?:typeof fetch}} options */
  constructor({url,apiKey,accessToken,workspace='agent-factory',fetchImpl=globalThis.fetch}) {
    const target=new URL(url);
    assert(target.protocol==='https:' && !target.username && !target.password, 'HTTPS Supabase URL required');
    assert(typeof apiKey==='string' && apiKey.length>0 && typeof accessToken==='string' && accessToken.length>0, 'Explicit credentials required');
    assert(typeof fetchImpl==='function', 'A Fetch implementation is required (Node.js 20+ provides one)');
    this.url=target.origin;this.apiKey=apiKey;this.accessToken=accessToken;this.workspace=workspace;this.fetch=fetchImpl;
  }
  async _rpc(name, params, signal) {
    const response=await this.fetch(`${this.url}/rest/v1/rpc/${name}`,{
      method:'POST',headers:{'Content-Type':'application/json',apikey:this.apiKey,Authorization:`Bearer ${this.accessToken}`},
      body:JSON.stringify(params),signal:signal||AbortSignal.timeout(25000)
    });
    const text=await response.text();let body;try{body=text?JSON.parse(text):{};}catch{throw new Error('Invalid API response');}
    if(!response.ok){const error=new Error(body.message||`API error ${response.status}`);error.code=body.code;error.status=response.status;throw error;}
    return body;
  }
  /** Read access still requires an active Workspace membership for a user token. */
  snapshot({signal}={}) {return this._rpc('agent_ops_operations_snapshot',{p_workspace_slug:this.workspace},signal);}
  /**
   * sourceKind must be explicitly selected. Runtime is trusted-server-only.
   * There is no auto-registration, background upload, or measurement inference.
   * No runs means no network request.
   */
  async writeRuns(runs,{sourceId,sourceKind,environment='production',signal}={}) {
    assert(Array.isArray(runs) && runs.length<=20000, 'Expected at most 20,000 actual runs');
    assert(typeof sourceId==='string' && ID.test(sourceId), 'Explicit non-personal sourceId required');
    assert(['runtime','manual','import'].includes(sourceKind), 'Explicit sourceKind required');
    assert(['production','staging','test'].includes(environment), 'Invalid environment');
    const identity=new Map();
    for(const run of runs){validateRunLog(run);const data=JSON.stringify(run);assert(!identity.has(run.runId)||identity.get(run.runId)===data,'Conflicting runId in input');identity.set(run.runId,data);}
    const chunks=[];let part=[],bytes=2;
    for(const value of identity.values()){
      const size=new TextEncoder().encode(value).length+1;
      if(part.length>=200||bytes+size>2097152){chunks.push(part);part=[];bytes=2;}
      part.push(JSON.parse(value));bytes+=size;
    }
    if(part.length)chunks.push(part);
    let inserted=0,deduplicated=0;
    try{
      for(const batch of chunks){
        const r=await this._rpc('agent_ops_operations_write',{p_workspace_slug:this.workspace,p_runs:batch,p_source_id:sourceId,p_source_kind:sourceKind,p_environment:environment},signal);
        inserted+=r.inserted;deduplicated+=r.deduplicated;
      }
      return{inserted,deduplicated};
    }catch(error){
      // An interrupted response may have committed. Preserve runId and read back
      // before retrying; the server rejects different content for an existing ID.
      error.confirmedInserted=inserted;error.confirmedDeduplicated=deduplicated;
      error.commitStatus='The last request may have committed; inspect storage before retrying.';
      throw error;
    }
  }
}
