/** LOCAL ONLY: reconstructs Agent Ops baseline in ephemeral in-memory PostgreSQL.
 * No Supabase client, HTTP request, credential, user data or remote writes.
 * auth.uid and cron.schedule are explicitly local test substitutes.
 */
import {PGlite} from '@electric-sql/pglite';
import {readFileSync, readdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
export const fixtureDir=fileURLToPath(new URL('./fixtures/',import.meta.url)).replace(/\/$/,'');
export const repoRoot=fileURLToPath(new URL('../../',import.meta.url)).replace(/\/$/,'');
const read=n=>readFileSync(fixtureDir+'/'+n,'utf8');
const json=n=>JSON.parse(read(n));
export async function bootstrap(){
const db=new PGlite();
await db.exec(`create role anon; create role authenticated; create role service_role bypassrls; create schema cron; create function cron.schedule(text,text,text) returns bigint language sql as $$select 1::bigint$$; create schema auth; create schema agent_ops; create table auth.users(id uuid primary key); create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$; grant usage on schema auth to anon,authenticated,service_role; grant usage on schema agent_ops to authenticated,service_role;`);
for(const t of json('schema.json').tables){
 const cols=t.columns.map(c=>`"${c.name}" ${c.format==='_text'?'text[]':c.format}${c.options.includes('nullable')?'':' not null'}${c.default_value?' default '+c.default_value:''}`);
 await db.exec(`create table ${t.name} (${cols.join(',')}); alter table ${t.name} enable row level security;`);
}
const constraints=json('constraints-indexes.json').filter(c=>c.kind==='constraint');
constraints.sort((a,b)=>Number(a.definition.startsWith('FOREIGN KEY'))-Number(b.definition.startsWith('FOREIGN KEY')));
for(const c of constraints)await db.exec(`alter table agent_ops.${c.table_name} add constraint ${c.name} ${c.definition};`);
for(const c of json('constraints-indexes.json').filter(c=>c.kind==='index'&&!constraints.some(x=>x.name===c.name)))await db.exec(c.definition);
for(const p of json('security.json'))await db.exec(`create policy ${p.policyname} on agent_ops.${p.tablename} for ${p.cmd} to ${p.roles.slice(1,-1)} ${p.qual?'using ('+p.qual+')':''} ${p.with_check?'with check ('+p.with_check+')':''};`);
for(const g of json('grants.json'))await db.exec(`grant ${g.privilege_type} on ${g.table_schema}.${g.table_name} to ${g.grantee};`);
for(const g of json('column_grants.json'))await db.exec(`grant ${g.privilege_type} (${g.column_name}) on agent_ops.${g.table_name} to ${g.grantee};`);
for(const f of readdirSync(fixtureDir).filter(f=>f.endsWith('.sql')))await db.exec(read(f));
for(const t of json('triggers.json').filter(t=>['agents_default_dna','chat_insert_guard','operation_runs_guard','guard_event'].includes(t.tgname)))await db.exec(t.definition);
for(const f of json('functions.json')){
 const def=await db.query('select pg_proc.oid::regprocedure::text sig from pg_proc join pg_namespace n on n.oid=pronamespace where n.nspname=$1 and proname=$2',[f.schema,f.name]);
 for(const p of def.rows){await db.exec(`revoke all on function ${p.sig} from public,anon,authenticated,service_role;`); if(f.acl.includes('authenticated='))await db.exec(`grant execute on function ${p.sig} to authenticated;`); if(f.acl.includes('service_role='))await db.exec(`grant execute on function ${p.sig} to service_role;`);}
}
return db;
}
