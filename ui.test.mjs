/**
 * Offline DOM contract tests. All fetches are intercepted, all fixtures below
 * exist only inside jsdom. No production request, log, or runtime proof is made.
 * Run: npm ci && node --test tests/ui.test.mjs
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {webcrypto} from 'node:crypto';
import {JSDOM,VirtualConsole} from 'jsdom';

const source=readFileSync(new URL('../index.html',import.meta.url),'utf8');
// Expose existing private functions only inside this isolated test document.
const html=source.replace('window.AgentOps={','window.__offlineTests={submitRuntime,retryRuntime,runtimeTurnProof,runtimeOutcome};window.AgentOps={');
const UUID='11111111-1111-4111-8111-111111111111';
const THREAD='22222222-2222-4222-8222-222222222222';
const now=()=>new Date().toISOString();
const clone=x=>JSON.parse(JSON.stringify(x));
function run(agentId,runId,status='success',kind='runtime'){
 return {id:runId,data:{runId,agentId,startedAt:now(),status,trigger:'user',parentAgentId:null,steps:[],_source:{id:'local-contract-fixture',kind,name:'Offline fixture only',createdAt:now()}}};
}
function baseData(role='editor'){
 const agents=['local-orchestrator','local-analyst','local-reviewer'].map((code,i)=>({code,name:code,short_name:code,is_orchestrator:i===0,lifecycle:'draft',runtime_status:'unverified',implementation_verified_at:null,dna_valid:true,requires_run_log:true}));
 return {role,settings:{ai_enabled:false},agents,threads:[],turns:[],pending:null};
}
function setup({role='editor',chat=baseData(role),runs=[],submit,execute}={}){
 const calls=[],errors=[];
 const transport={chat,runs,submit,execute};
 const vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
 const dom=new JSDOM(html,{url:'https://ai-teamspu.github.io/Agent-Operations/',runScripts:'dangerously',virtualConsole:vc,beforeParse(w){
  w.IntersectionObserver=class{observe(){} disconnect(){}};
  w.TextEncoder=TextEncoder;w.AbortController=AbortController;
  Object.defineProperty(w.crypto,'randomUUID',{value:()=>webcrypto.randomUUID()});
  w.setInterval=()=>1;w.clearInterval=()=>{};w.setTimeout=()=>1;w.clearTimeout=()=>{};
  w.HTMLElement.prototype.scrollIntoView=()=>{};
  w.HTMLDialogElement.prototype.showModal=function(){this.setAttribute('open','');};
  w.HTMLDialogElement.prototype.close=function(){this.removeAttribute('open');};
  w.fetch=async(url,init={})=>{
   const path=new URL(url).pathname,body=init.body?JSON.parse(init.body):null;
   calls.push({path,body});let data;
   if(path==='/auth/v1/user')data={id:UUID,email:'offline-test@example.invalid',email_confirmed_at:now(),is_anonymous:false};
   else if(path==='/auth/v1/logout')data={};
   else if(path.endsWith('/agent_ops_operations_snapshot'))data={schemaVersion:3,generatedAt:now(),memberRole:role,scope:{environment:'production',registryPolicy:'admin_attested_implementation_only',truncated:false,rows:transport.runs.length},coverage:{runtimeRuns:transport.runs.length,manualRuns:0,importedRuns:0},registry:{agents:[],skills:[]},runs:clone(transport.runs)};
   else if(path.endsWith('/agent_ops_chat_state'))data=clone(transport.chat);
   else if(path.endsWith('/agent_ops_submit_chat')||path.endsWith('/agent_ops_submit_orchestration')){if(!transport.submit)throw Error('Unexpected submission in offline test');data=await transport.submit(body,path);}
   else if(path==='/functions/v1/agent-ops-chat'){if(!transport.execute)throw Error('Unexpected runtime execution in offline test');data=await transport.execute(body);}
   else throw Error('Unrecognized intercepted request: '+path);
   return {ok:true,status:200,text:async()=>JSON.stringify(data),json:async()=>clone(data)};
  };
 }});
 const w=dom.window;
 const login=()=>w.AgentOps.useAccessToken('offline-contract-token-no-authentication-power');
 return {w,dom,calls,errors,transport,login,close:()=>dom.window.close()};
}
function choose(w,id='local-analyst'){w.document.getElementById('runtimeAgent').value=id;w.document.getElementById('runtimeAgent').dispatchEvent(new w.Event('change'));}
function turn(status='queued'){
 return {id:UUID,thread_id:THREAD,agent_code:'local-analyst',run_id:'local-contract-run',user_content:'Offline fixture request',assistant_content:null,status,error_code:null,created_at:now()};
}
function markSubmitted(env,status='queued'){
 env.transport.chat.threads=[{id:THREAD,agent_code:'local-analyst',title:'Offline fixture thread',created_at:now()}];
 env.transport.chat.turns=[turn(status)];env.transport.chat.pending=status==='queued'?{id:UUID,thread_id:THREAD,status}:null;
}

test('anonymous empty page creates no data or requests and cannot dispatch',()=>{
 const e=setup();try{assert.equal(e.calls.length,0);assert.equal(e.w.AgentOps.getRunEvidence(),null);assert.equal(e.w.document.querySelectorAll('#runtimeEvidence [data-run-id]').length,0);assert.equal(e.w.document.getElementById('runtimeSend').disabled,true);assert.equal(e.w.document.querySelectorAll('#runtimeParticipants input').length,0);assert.deepEqual(e.errors,[]);}finally{e.close();}
});

test('viewer reads real-empty contract but cannot submit; unverified roster is shown',async()=>{
 const e=setup({role:'viewer'});try{await e.login();assert.equal(e.w.AgentOps.getRunEvidence().length,0);assert.equal(e.w.document.getElementById('runtimeSend').disabled,true);assert.equal(e.w.document.querySelectorAll('#runtimeAgent option').length,4);assert.match(e.w.document.getElementById('runtimeAgent').textContent,/ทะเบียนยังไม่ยืนยัน/);assert.equal(e.calls.some(c=>/submit|functions\/v1/.test(c.path)),false);assert.deepEqual(e.errors,[]);}finally{e.close();}
});

test('multi selector uses registry orchestrators and excludes coordinator from children',async()=>{
 const e=setup();try{await e.login();const mode=e.w.document.getElementById('runtimeMode');mode.value='multi';mode.dispatchEvent(new e.w.Event('change'));assert.equal(e.w.document.querySelectorAll('#runtimeAgent option').length,2);choose(e.w,'local-orchestrator');assert.equal(e.w.document.querySelector('#runtimeParticipants input[value="local-orchestrator"]').disabled,true);assert.equal(e.w.document.querySelector('#runtimeParticipants input[value="local-analyst"]').disabled,false);assert.equal(e.w.document.getElementById('runtimeAgents').hidden,false);assert.equal(e.w.document.getElementById('runtimeStatus').disabled,true);await assert.rejects(()=>e.w.__offlineTests.submitRuntime('Offline test only'),/2–3/);assert.equal(e.calls.some(c=>c.path.includes('submit')),false);}finally{e.close();}
});

test('lost submission response preserves requestId on retry instead of creating new run',async()=>{
 const e=setup();let attempts=0;
 e.transport.submit=async()=>{attempts++;if(attempts===1)throw new TypeError('Offline response intentionally lost');markSubmitted(e);return{id:UUID,threadId:THREAD,status:'queued',deduplicated:true};};
 e.transport.execute=async()=>({id:UUID,status:'running',retryMode:'execute_same_turn'});
 try{await e.login();choose(e.w);await e.w.__offlineTests.submitRuntime('Offline request');const requestId=e.calls.find(c=>c.path.endsWith('agent_ops_submit_chat')).body.p_request_id;await e.w.__offlineTests.retryRuntime();const submissions=e.calls.filter(c=>c.path.endsWith('agent_ops_submit_chat'));assert.equal(submissions.length,2);assert.equal(submissions[1].body.p_request_id,requestId);assert.equal(e.calls.find(c=>c.path.includes('/functions/v1/')).body.turnId,UUID);assert.equal(e.w.AgentOps.getRunEvidence().length,0);}finally{e.close();}
});

test('multi dispatch submits only selected agents and executes the returned parent turn',async()=>{
 const e=setup();
 e.transport.submit=async(body,path)=>{assert.match(path,/agent_ops_submit_orchestration$/);markSubmitted(e);e.transport.chat.turns[0].agent_code='local-orchestrator';e.transport.chat.threads[0].agent_code='local-orchestrator';return{id:UUID,threadId:THREAD,status:'queued'};};
 e.transport.execute=async()=>({id:UUID,status:'running',retryMode:'execute_same_turn'});
 try{await e.login();const mode=e.w.document.getElementById('runtimeMode');mode.value='multi';mode.dispatchEvent(new e.w.Event('change'));choose(e.w,'local-orchestrator');for(const code of ['local-analyst','local-reviewer'])e.w.document.querySelector(`#runtimeParticipants input[value="${code}"]`).checked=true;await e.w.__offlineTests.submitRuntime('Offline multi request');const submitted=e.calls.find(c=>c.path.endsWith('/agent_ops_submit_orchestration')).body;assert.equal(submitted.p_orchestrator_code,'local-orchestrator');assert.deepEqual(submitted.p_agent_codes,['local-analyst','local-reviewer']);assert.equal(submitted.p_workspace_slug,'agent-factory');assert.equal(Object.hasOwn(submitted,'runId'),false);assert.equal(e.calls.find(c=>c.path.includes('/functions/v1/')).body.turnId,UUID);assert.equal(e.w.AgentOps.getRunEvidence().length,0);}finally{e.close();}
});

test('lost execute response retries the same turnId without resubmitting',async()=>{
 const e=setup();let attempts=0;
 e.transport.submit=async()=>{markSubmitted(e);return{id:UUID,threadId:THREAD,status:'queued'};};
 e.transport.execute=async()=>{attempts++;if(attempts===1)throw new TypeError('Offline response intentionally lost');return{id:UUID,status:'running',retryMode:'execute_same_turn'};};
 try{await e.login();choose(e.w);await e.w.__offlineTests.submitRuntime('Offline request');await e.w.__offlineTests.retryRuntime();assert.equal(e.calls.filter(c=>c.path.endsWith('agent_ops_submit_chat')).length,1);assert.deepEqual(e.calls.filter(c=>c.path.includes('/functions/v1/')).map(c=>c.body.turnId),[UUID,UUID]);assert.equal(e.w.document.getElementById('runtimeSend').disabled,true);assert.equal(e.w.document.querySelectorAll('#runtimeEvidence [data-run-id]').length,0);}finally{e.close();}
});

test('completion requires matching runtime rows, receipt logging, successful children and gate',async()=>{
 const e=setup();try{
  await e.login();
  const parent={...turn('succeeded'),run_id:'local-parent',agent_code:'local-orchestrator',orchestration_id:'offline-orchestration',receipt:{agentId:'local-orchestrator',runId:'local-parent',status:'succeeded',logging:'logged',children:[{agentId:'local-analyst',runId:'local-child-a',status:'succeeded',logging:'logged'},{agentId:'local-reviewer',runId:'local-child-b',status:'succeeded',logging:'logged'}],gate:{complete:true}}};
  assert.equal(e.w.__offlineTests.runtimeTurnProof(parent).complete,false);
  e.transport.runs=[run('local-orchestrator','local-parent'),run('local-analyst','local-child-a'),run('local-reviewer','local-child-b')];await e.w.AgentOps.refresh();
  assert.equal(e.w.__offlineTests.runtimeTurnProof(parent).complete,true);
  const wrongTurn=clone(parent);wrongTurn.run_id='different-persisted-turn-run';assert.equal(e.w.__offlineTests.runtimeTurnProof(wrongTurn).complete,false);
  const wrongAgent=clone(parent);wrongAgent.receipt.children[0].agentId='wrong-agent';assert.equal(e.w.__offlineTests.runtimeTurnProof(wrongAgent).complete,false);
  const unlogged=clone(parent);unlogged.receipt.logging='unconfirmed';assert.equal(e.w.__offlineTests.runtimeTurnProof(unlogged).complete,false);
  const gateFailed=clone(parent);gateFailed.receipt.gate.complete=false;assert.equal(e.w.__offlineTests.runtimeTurnProof(gateFailed).complete,false);
  const childFailed=clone(parent);childFailed.receipt.children[0].status='failed';assert.equal(e.w.__offlineTests.runtimeTurnProof(childFailed).complete,false);
  const duplicate=clone(parent);duplicate.receipt.children[1]=clone(duplicate.receipt.children[0]);assert.equal(e.w.__offlineTests.runtimeTurnProof(duplicate).complete,false);
  e.transport.runs[0].data._source.kind='manual';await e.w.AgentOps.refresh();assert.equal(e.w.__offlineTests.runtimeTurnProof(parent).complete,false);
  e.transport.runs[0].data._source.kind='runtime';e.transport.runs[2].data.status='failed';await e.w.AgentOps.refresh();assert.equal(e.w.__offlineTests.runtimeTurnProof(parent).complete,false);
 }finally{e.close();}
});

test('logged failed run remains visible, never labelled completed',async()=>{
 const t={...turn('failed'),error_code:'OFFLINE_FAILURE_FIXTURE',receipt:{agentId:'local-analyst',runId:'local-contract-run',status:'failed',logging:'logged'}};
 const chat=baseData();chat.turns=[t];
 const e=setup({chat,runs:[run('local-analyst','local-contract-run','failed')]});
 try{await e.login();assert.equal(e.w.__offlineTests.runtimeTurnProof(t).complete,false);assert.match(e.w.__offlineTests.runtimeOutcome(t).label,/ไม่สำเร็จ/);assert.equal(e.w.document.querySelectorAll('#runtimeEvidence [data-run-id]').length,1);assert.match(e.w.document.getElementById('runtimeThread').textContent,/OFFLINE_FAILURE_FIXTURE/);}finally{e.close();}
});

test('sign-out clears private messages and RUN_LOG evidence',async()=>{
 const chat=baseData();chat.turns=[{...turn('failed'),user_content:'PRIVATE_LOCAL_FIXTURE',assistant_content:'PRIVATE_OUTPUT_FIXTURE'}];
 const e=setup({chat,runs:[run('local-analyst','local-contract-run','failed')]});
 try{await e.login();assert.match(e.w.document.getElementById('runtimeThread').textContent,/PRIVATE_LOCAL_FIXTURE/);await e.w.AgentOps.signOut();assert.doesNotMatch(e.w.document.getElementById('runtimeThread').textContent,/PRIVATE/);assert.equal(e.w.AgentOps.getRunEvidence(),null);assert.equal(e.w.document.querySelectorAll('#runtimeEvidence [data-run-id]').length,0);assert.equal(e.w.document.querySelectorAll('#runtimeParticipants input').length,0);assert.equal(e.w.document.getElementById('runtimeSend').disabled,true);assert.deepEqual(e.errors,[]);}finally{e.close();}
});
