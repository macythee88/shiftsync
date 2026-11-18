-- ShiftSync GPS + fixed QR attendance: READ-ONLY preflight
-- Run BEFORE the attendance migration in Supabase SQL Editor.
-- This script only reads metadata and existing store data.

with checks as (
  select 'emp_data.emp_id type' check_name,
    coalesce((select format_type(a.atttypid,a.atttypmod) from pg_attribute a
      where a.attrelid='public.emp_data'::regclass and a.attname='emp_id' and not a.attisdropped),'MISSING') actual,
    'text' expected
  union all select 'emp_data.punches type',
    coalesce((select format_type(a.atttypid,a.atttypmod) from pg_attribute a
      where a.attrelid='public.emp_data'::regclass and a.attname='punches' and not a.attisdropped),'MISSING'),'jsonb'
  union all select 'emp_data.user_id type',
    coalesce((select format_type(a.atttypid,a.atttypmod) from pg_attribute a
      where a.attrelid='public.emp_data'::regclass and a.attname='user_id' and not a.attisdropped),'MISSING'),'uuid'
  union all select 'public.is_mgr()',
    case when to_regprocedure('public.is_mgr()') is null then 'MISSING' else 'present' end,'present'
  union all select 'public.punch_me()',
    case when to_regprocedure('public.punch_me()') is null then 'MISSING' else 'present' end,'present (will be revoked during cutover)'
  union all select 'pgcrypto extension schema',
    coalesce((select n.nspname from pg_extension e join pg_namespace n on n.oid=e.extnamespace where e.extname='pgcrypto'),'NOT INSTALLED'),
    'extensions'
  union all select 'extensions schema',
    case when exists(select 1 from pg_namespace where nspname='extensions') then 'present' else 'MISSING' end,'present'
  union all select 'emp_data RLS',
    case when (select relrowsecurity from pg_class where oid='public.emp_data'::regclass) then 'enabled' else 'disabled' end,'enabled'
  union all select 'manager table',
    case when to_regclass('public.managers') is null then 'MISSING' else 'present' end,'present'
  union all select 'stores table before migration',
    case when to_regclass('public.stores') is null then 'not created yet' else 'already exists' end,
    'not created yet (or review existing table before migration)'
)
select check_name,actual,expected,
 case
  when check_name in ('emp_data.emp_id type','emp_data.punches type','emp_data.user_id type','public.is_mgr()','public.punch_me()','emp_data RLS','manager table')
       and actual=expected then 'OK'
  when check_name='extensions schema' and actual='present' then 'OK'
  when check_name in ('pgcrypto extension schema','stores table before migration') then 'REVIEW'
  else 'CHECK'
 end status
from checks order by check_name;

-- Existing triggers and RLS policies must be reviewed for compatibility.
select 'TRIGGER' item_type,t.tgname item_name,pg_get_triggerdef(t.oid) definition
from pg_trigger t where t.tgrelid='public.emp_data'::regclass and not t.tgisinternal
union all
select 'POLICY',p.policyname,
 'cmd='||p.cmd||'; roles='||array_to_string(p.roles,',')||'; using='||coalesce(p.qual,'')||'; check='||coalesce(p.with_check,'')
from pg_policies p where p.schemaname='public' and p.tablename in ('emp_data','managers');
