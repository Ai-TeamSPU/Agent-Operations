-- Read-only HR/DL isolation fingerprint. No table rows, user details, or secrets.
-- Run before/after Agent Operations deployment and compare fingerprint + objects.
-- Only agent_ops schema and public.agent_ops_* RPCs may change in this release.
WITH scoped_namespaces AS (
  SELECT oid, nspname, nspowner::regrole::text AS owner, nspacl::text AS acl
  FROM pg_namespace WHERE nspname IN ('public','private','auth','storage')
), table_objects AS (
  SELECT 'table'::text AS category, n.nspname||'.'||c.relname AS object_name,
    jsonb_build_object(
      'kind',c.relkind,'rls',c.relrowsecurity,'forceRls',c.relforcerowsecurity,
      'owner',c.relowner::regrole::text,'acl',c.relacl::text,'options',c.reloptions,
      'columns',COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'name',a.attname,'position',a.attnum,'type',pg_catalog.format_type(a.atttypid,a.atttypmod),
          'notNull',a.attnotnull,'identity',a.attidentity,'generated',a.attgenerated,
          'default',pg_get_expr(d.adbin,d.adrelid),'acl',a.attacl::text
        ) ORDER BY a.attnum)
        FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
        WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
      ),'[]'::jsonb),
      'constraints',COALESCE((
        SELECT jsonb_agg(jsonb_build_object('name',co.conname,'def',pg_get_constraintdef(co.oid),'validated',co.convalidated) ORDER BY co.conname)
        FROM pg_constraint co WHERE co.conrelid=c.oid
      ),'[]'::jsonb),
      'indexes',COALESCE((
        SELECT jsonb_agg(jsonb_build_object('name',ci.relname,'def',pg_get_indexdef(i.indexrelid),'valid',i.indisvalid) ORDER BY ci.relname)
        FROM pg_index i JOIN pg_class ci ON ci.oid=i.indexrelid WHERE i.indrelid=c.oid
      ),'[]'::jsonb),
      'triggers',COALESCE((
        SELECT jsonb_agg(jsonb_build_object('name',t.tgname,'def',pg_get_triggerdef(t.oid),'enabled',t.tgenabled) ORDER BY t.tgname)
        FROM pg_trigger t WHERE t.tgrelid=c.oid AND NOT t.tgisinternal
      ),'[]'::jsonb),
      'viewDefinition',CASE WHEN c.relkind IN ('v','m') THEN pg_get_viewdef(c.oid,true) ELSE NULL END
    ) AS metadata
  FROM pg_class c JOIN scoped_namespaces n ON n.oid=c.relnamespace
  WHERE c.relkind IN ('r','p','v','m')
), function_objects AS (
  SELECT 'function'::text AS category,
    n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')' AS object_name,
    jsonb_build_object('definition',pg_get_functiondef(p.oid),'owner',p.proowner::regrole::text,'acl',p.proacl::text) AS metadata
  FROM pg_proc p JOIN scoped_namespaces n ON n.oid=p.pronamespace
  WHERE p.prokind IN ('f','p') AND NOT(n.nspname='public' AND p.proname LIKE 'agent\_ops\_%' ESCAPE '\')
), policy_objects AS (
  SELECT 'policy'::text AS category,p.schemaname||'.'||p.tablename||'.'||p.policyname AS object_name,
    jsonb_build_object('permissive',p.permissive,'roles',p.roles,'cmd',p.cmd,'qual',p.qual,'check',p.with_check) AS metadata
  FROM pg_policies p WHERE p.schemaname IN (SELECT nspname FROM scoped_namespaces)
), enum_objects AS (
  SELECT 'enum'::text AS category,n.nspname||'.'||t.typname AS object_name,
    jsonb_build_object('labels',jsonb_agg(e.enumlabel ORDER BY e.enumsortorder)) AS metadata
  FROM pg_type t JOIN scoped_namespaces n ON n.oid=t.typnamespace JOIN pg_enum e ON e.enumtypid=t.oid
  GROUP BY n.nspname,t.typname
), schema_objects AS (
  SELECT 'schema'::text AS category,nspname AS object_name,jsonb_build_object('owner',owner,'acl',acl) AS metadata FROM scoped_namespaces
), all_objects AS (
  SELECT * FROM table_objects UNION ALL SELECT * FROM function_objects UNION ALL SELECT * FROM policy_objects UNION ALL SELECT * FROM enum_objects UNION ALL SELECT * FROM schema_objects
), hashed AS (
  SELECT category,object_name,md5(metadata::text) AS definition_hash FROM all_objects
)
SELECT jsonb_build_object(
  'fingerprintVersion',1,
  'projectRef','doxunxbgqmybyckczucg',
  'scope',jsonb_build_array('public except public.agent_ops_* functions','private','auth metadata only','storage metadata only'),
  'exclusions',jsonb_build_array('agent_ops schema','table row data','auth settings outside PostgreSQL','Edge Function configuration','secrets'),
  'fingerprint',md5((SELECT string_agg(category||':'||object_name||'='||definition_hash,E'\n' ORDER BY category,object_name) FROM hashed)),
  'objectCounts',(SELECT jsonb_object_agg(category,total) FROM (SELECT category,count(*) AS total FROM hashed GROUP BY category) q),
  'objects',(SELECT jsonb_agg(jsonb_build_object('category',category,'name',object_name,'hash',definition_hash) ORDER BY category,object_name) FROM hashed)
) AS isolation_fingerprint;
