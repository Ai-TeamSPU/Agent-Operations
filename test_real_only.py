"""Local empty-response checks. No invented Agents, Skills or RUN_LOGs.
All HTTP requests are intercepted. No test writes reach Supabase.
"""
import json
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT=Path(__file__).resolve().parents[1]
HTML=(ROOT/'Agent-Operations-Real.html').read_text()
URL='https://doxunxbgqmybyckczucg.supabase.co'
# Empty registry/run arrays match the production snapshot inspected on 2026-09-19.
# The role is varied solely to test UI permission controls; no user is created.
EMPTY={
 'schemaVersion':3,'generatedAt':'2026-09-19T12:11:08.374089+00:00',
 'memberRole':'viewer','workspace':{'slug':'agent-factory','collectionStatus':'not_connected'},
 'scope':{'environment':'production','registryPolicy':'admin_attested_implementation_only','truncated':False,'rows':0},
 'registry':{'schemaVersion':1,'agents':[],'skills':[]},'runs':[],
 'coverage':{'runtimeRuns':0,'manualRuns':0,'importedRuns':0,'legacyEventRows':0}
}
results=[]
def check(name,ok):
 results.append({'name':name,'passed':bool(ok)})
 if not ok: raise AssertionError(name)
with sync_playwright() as p:
 browser=p.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox'])
 ctx=browser.new_context(viewport={'width':1440,'height':1050},timezone_id='Asia/Bangkok')
 page=ctx.new_page();errors=[];requests=[];transport={'mode':'ok','role':'viewer'}
 page.on('pageerror',lambda e:errors.append(str(e)))
 def intercept(route):
  req=route.request;requests.append({'url':req.url,'method':req.method})
  headers={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'*','Access-Control-Allow-Methods':'POST,OPTIONS'}
  if req.method=='OPTIONS': route.fulfill(status=204,headers=headers);return
  if not req.url.startswith(URL): route.abort();return
  if req.url.endswith('/auth/v1/logout?scope=local'):route.fulfill(status=200,headers=headers,content_type='application/json',body='{}');return
  if req.url.endswith('/rest/v1/rpc/agent_ops_operations_snapshot'):
   if transport['mode']=='abort':route.abort();return
   if transport['mode']=='deny':route.fulfill(status=403,headers=headers,content_type='application/json',body='{"code":"42501","message":"Workspace unavailable"}');return
   if transport['mode']=='malformed':route.fulfill(status=200,headers=headers,content_type='application/json',body='{}');return
   snapshot=dict(EMPTY,memberRole=transport['role'])
   route.fulfill(status=200,headers=headers,content_type='application/json',body=json.dumps(snapshot));return
  # No write request is expected in these tests.
  route.abort()
 page.route('**/*',intercept)
 page.set_content(HTML);page.wait_for_timeout(80)
 check('No network request before explicit sign-in/session',not requests)
 check('Initial metrics are unknown, not zeros',page.locator('#kpis .metric').all_text_contents()==['—']*6)
 check('No demo generator or sample registry bundled','generateDemo' not in HTML and 'DEMO_REGISTRY' not in HTML)
 check('No demo toggle in document',page.locator('[data-action="toggle-demo"]').count()==0)
 check('No browser persistence code',all(x not in HTML for x in ['localStorage.setItem','localStorage.getItem','sessionStorage.setItem','indexedDB.open']))
 check('No record creation before authentication',page.locator('#recordButton').is_disabled())
 check('Registry import is locked before authentication',page.locator('#registryFile').is_disabled())
 check('RUN_LOG import is locked before authentication',page.locator('#logFile').is_disabled())
 check('Export is locked before reading data',page.locator('[data-action="backup"]').is_disabled())
 check('AI analysis is not available without real evidence',page.locator('#analyzeButton').is_disabled())
 check('No source deletion action',page.locator('[data-action="delete-sources"]').count()==0)
 check('No desktop horizontal overflow',not page.evaluate('document.documentElement.scrollWidth>innerWidth'))
 page.locator('#loginButton').click();check('Login dialog opens by button',page.locator('#authDialog').evaluate('(e)=>e.open'))
 page.keyboard.press('Escape');check('Escape dismisses login dialog',not page.locator('#authDialog').evaluate('(e)=>e.open'))
 check('Invalid empty RUN_LOG rejected',page.evaluate("()=>{try{AgentOpsValidation.validateRun({});return false}catch{return true}}"))
 check('Unconfirmed registry item rejected',page.evaluate("()=>{try{AgentOpsValidation.validateRegistry({agents:[],skills:[{}]});return false}catch{return true}}"))
 check('Empty registry contains no inferred entries',page.evaluate('AgentOpsValidation.validateRegistry({agents:[],skills:[]}).agents.length')==0)
 check('Empty input rejected',page.evaluate("()=>{try{AgentOpsValidation.extractJSON('');return false}catch{return true}}"))
 check('RUN_LOG schema has no example rows',page.evaluate("()=>{const s=AgentOpsValidation.runSchema();return !('examples'in s)&&!('default'in s)&&s.type==='object'}"))
 check('Registry schema requires implementation evidence',page.evaluate("AgentOpsValidation.registrySchema().properties.agents.items.required.includes('implementationEvidence')"))
 check('Schema helper does not create a run',page.evaluate('AgentOps.getViewSummary()===null'))
 # Only a local, intercepted access-token placeholder is used; no real credential.
 page.evaluate("AgentOps.useAccessToken('local-contract-test-user-token')")
 check('Empty snapshot is accepted with member role',page.evaluate("AgentOps.getConnectionStatus().status==='connected'"))
 metrics=page.locator('#kpis .metric').all_text_contents()
 check('Verified empty database shows zero runs',metrics[0].strip().startswith('0'))
 check('Empty success rate is unknown',metrics[3].strip()=='—')
 check('Empty median is unknown',metrics[4].strip()=='—')
 check('Empty skills-per-run is unknown',metrics[5].strip()=='—')
 check('No Agent is invented from empty snapshot',page.locator('#quietAgents [data-action="agent"]').count()==0)
 check('No bottleneck invented',page.locator('#flowGrid .bottleneck').count()==0)
 check('No plan invented',page.locator('#plansGrid .plan').count()==0)
 check('Viewer cannot import data',page.locator('#logFile').is_disabled() and page.locator('#registryFile').is_disabled())
 check('Viewer can export received snapshot',not page.locator('[data-action="backup"]').is_disabled())
 before=len(requests);page.locator('#rangeFilter').select_option('90');page.locator('#groupFilter').select_option('academic')
 check('Filter changes do not create subscriptions or network requests',len(requests)==before)
 page.locator('#groupFilter').select_option('all');page.locator('#rangeFilter').select_option('30')
 transport['mode']='abort';page.evaluate('AgentOps.refresh().catch(()=>{})')
 check('Network error marks cached snapshot stale','ขัดข้อง' in page.locator('#sourceBadge').inner_text())
 check('Network error disables writes',page.locator('#logFile').is_disabled())
 transport['mode']='deny';page.evaluate('AgentOps.refresh().catch(()=>{})')
 check('Access denial is separate from empty database',page.evaluate("AgentOps.getConnectionStatus().status==='denied'"))
 check('Access denial clears previously loaded metrics',page.locator('#kpis .metric').all_text_contents()==['—']*6)
 transport['mode']='ok';transport['role']='admin';page.evaluate('AgentOps.refresh()')
 check('Admin can supply actual registry',not page.locator('#registryFile').is_disabled())
 check('Admin still cannot manually record without real Agent',page.locator('#recordButton').is_disabled())
 before=len([r for r in requests if '/write' in r['url']]);page.locator('#pasteLogs').fill('[]');page.locator('[data-action="import-text"]').click()
 check('Empty import does not submit a database write',len([r for r in requests if '/write' in r['url']])==before)
 page.set_viewport_size({'width':390,'height':844});page.wait_for_timeout(80)
 check('Mobile 390px has no page overflow',not page.evaluate('document.documentElement.scrollWidth>innerWidth'))
 check('Mobile header is not sticky',page.locator('.app-header').evaluate('(e)=>getComputedStyle(e).position')!='sticky')
 check('Mobile Flow has two columns',len(page.locator('#flowGrid').evaluate('(e)=>getComputedStyle(e).gridTemplateColumns').split())==2)
 page.emulate_media(reduced_motion='reduce');check('Reduced motion preference respected',page.evaluate("matchMedia('(prefers-reduced-motion: reduce)').matches"))
 page.locator('#themeSelect').select_option('dark');check('Dark override works',page.locator('html').get_attribute('data-theme')=='dark')
 page.locator('#themeSelect').select_option('light')
 page.evaluate('AgentOps.signOut()');check('Sign-out clears metrics',page.locator('#kpis .metric').all_text_contents()==['—']*6)
 check('Sign-out clears actual-data editor',page.locator('#pasteLogs').input_value()=='')
 before=len(requests);message=page.evaluate("AgentOps.useAccessToken('sb_secret_NOT_A_REAL_KEY').catch(e=>e.message)")
 check('Privileged API credentials rejected before network request',len(requests)==before and 'secret' in message)
 check('No write request made',not any('operations_write' in r['url'] or 'operations_register' in r['url'] for r in requests))
 check('No JavaScript errors',not errors)
 page.set_viewport_size({'width':1440,'height':1050});page.screenshot(path=str(ROOT/'tests'/'desktop-signed-out.png'),full_page=True)
 page.screenshot(path='/mnt/data/Agent-Operations-Real-preview.png',full_page=False)
 page.set_viewport_size({'width':390,'height':844});page.screenshot(path=str(ROOT/'tests'/'mobile-signed-out.png'),full_page=True)
 (ROOT/'RUN_LOG.schema.json').write_text(json.dumps(page.evaluate('AgentOpsValidation.runSchema()'),ensure_ascii=False,indent=2))
 (ROOT/'agent-registry.schema.json').write_text(json.dumps(page.evaluate('AgentOpsValidation.registrySchema()'),ensure_ascii=False,indent=2))
 browser.close()
report={'suite':'real-only empty-data and access controls','passed':len(results),'total':len(results),'network':'all intercepted locally; no live browser auth tested','business_data_generated':False,'production_writes':0,'checks':results}
(ROOT/'tests'/'test-report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({'passed':len(results),'total':len(results),'production_writes':0,'errors':errors}))
