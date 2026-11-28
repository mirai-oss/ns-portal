#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""入金まわりの権限漏れ修正の実環境リハーサル（流して必ず巻き戻す）。全ロールの実ユーザー（アルバイトは 2 人）の権限で、適用前後の見え方を測る。"""
import json, os, re, sys, time, urllib.request, urllib.error
HERE = os.path.dirname(os.path.abspath(__file__))
rd = lambda n: open(os.path.join(HERE, '..', '..', 'supabase', n), encoding='utf-8').read()
FIX, RB = rd('2026-11-28_deposit_access_fix.sql'), rd('2026-11-28_deposit_access_fix_ROLLBACK.sql')
M = "insert into _s select '%PH%', u.id, u.role, (select count(*) from public.ar_deposits), (select count(*) from public.ar_receivables), (select count(*) from public.ar_matching), (select count(*) from public.ar_receivable_attachments), (select count(*) from public.ar_recurring_master), (select count(*) from public.kd_deposit_daily), (select count(*) from public.kd_deposit_monthly_summary), (select count(*) from public.kd_deposit_daily_v), (select count(*) from public.kd_deposit_carry_v);"
LOOP = """  for u in select id, role from _u order by role, id loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true);
    set local role authenticated;
    %s
    reset role;
  end loop;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
"""
body = r"""
do $__r__$
declare fx text := $__f__$__FIX__$__f__$; rb text := $__rb__$__RB__$__rb__$; u record; res jsonb := '{}'::jsonb; pol0 text; pol1 text; gr0 text; gr1 text; t0 timestamptz; ms numeric;
  cur_pol text := $q$select md5(coalesce(string_agg(schemaname||tablename||policyname||cmd||roles::text||coalesce(qual,'')||coalesce(with_check,''),'|' order by schemaname,tablename,policyname),'')) from pg_policies where tablename like 'ar\_%' or tablename like 'kd\_deposit%'$q$;
  cur_gr text := $q$select md5(coalesce(string_agg(table_name||grantee||privilege_type,'|' order by table_name,grantee,privilege_type),'')) from information_schema.role_table_grants where table_schema='public' and (table_name like 'ar\_%' or table_name like 'kd\_deposit%')$q$;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute cur_pol into pol0; execute cur_gr into gr0;
  create temporary table _s (ph text, uid uuid, role text, ar_dep int, ar_rec int, ar_match int, ar_att int, ar_rm int, kd_d int, kd_m int, kd_dv int, kd_cv int) on commit drop; grant insert on _s to authenticated;
  create temporary table _u as select id, role from (select id, role, row_number() over (partition by role order by id) rn from public.users where is_active) q where role <> 'AL' or rn <= 2;
  grant select on _u to authenticated;
__A__
  execute fx;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
__B__
  res := res || jsonb_build_object('users_measured', (select count(*) from _u),
    'changed', (select coalesce(jsonb_agg(jsonb_build_object('role', a.role, 'limited', exists (select 1 from info.user_corporations x where x.user_id = a.uid), 'override_invoices', exists (select 1 from public.portal_user_overrides po where po.user_id = a.uid and po.system_key = 'invoices' and po.allowed),
       'ar_dep', a.ar_dep || '->' || b.ar_dep, 'ar_rec', a.ar_rec || '->' || b.ar_rec, 'ar_match', a.ar_match || '->' || b.ar_match, 'ar_att', a.ar_att || '->' || b.ar_att, 'ar_rm', a.ar_rm || '->' || b.ar_rm, 'kd_d', a.kd_d || '->' || b.kd_d, 'kd_m', a.kd_m || '->' || b.kd_m)), '[]'::jsonb)
      from _s a join _s b on a.uid = b.uid and a.ph = 'A' and b.ph = 'B' where (a.ar_dep, a.ar_rec, a.ar_match, a.ar_att, a.ar_rm, a.kd_d, a.kd_m, a.kd_dv, a.kd_cv) is distinct from (b.ar_dep, b.ar_rec, b.ar_match, b.ar_att, b.ar_rm, b.kd_d, b.kd_m, b.kd_dv, b.kd_cv)),
    'unchanged', (select count(*) from _s a join _s b on a.uid = b.uid and a.ph = 'A' and b.ph = 'B' where (a.ar_dep, a.ar_rec, a.ar_match, a.ar_att, a.ar_rm, a.kd_d, a.kd_m, a.kd_dv, a.kd_cv) is not distinct from (b.ar_dep, b.ar_rec, b.ar_match, b.ar_att, b.ar_rm, b.kd_d, b.kd_m, b.kd_dv, b.kd_cv)),
    'invoice_can_access_users', (select count(*) from public.users uu where uu.is_active and (uu.is_master or uu.role in ('CEO','HQ') or exists (select 1 from public.portal_user_overrides po where po.user_id = uu.id and po.system_key = 'invoices' and po.allowed))),
    'override_users_not_hq', (select count(*) from public.portal_user_overrides po join public.users uu on uu.id = po.user_id where po.system_key = 'invoices' and po.allowed and uu.is_active and not (uu.is_master or uu.role in ('CEO','HQ'))));
  -- 所要時間（社長・本部）
  select id into u from public.users where role = 'CEO' and is_active limit 1;
  perform set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true); set local role authenticated;
  t0 := clock_timestamp(); perform count(*) from public.kd_deposit_daily; perform count(*) from public.ar_deposits; perform count(*) from public.kd_deposit_monthly_summary; ms := extract(epoch from clock_timestamp() - t0) * 1000; reset role;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  res := res || jsonb_build_object('ceo_ms', round(ms));
  execute rb; execute cur_pol into pol1; execute cur_gr into gr1;
  res := res || jsonb_build_object('rollback_policies_identical', pol0 = pol1, 'rollback_grants_identical', gr0 = gr1);
  raise exception '#DEP#%', res::text;
end $__r__$;
"""
body = body.replace('__A__', LOOP % M.replace('%PH%', 'A')).replace('__B__', LOOP % M.replace('%PH%', 'B')).replace('__FIX__', FIX).replace('__RB__', RB)
pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
req = urllib.request.Request('https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query', data=json.dumps({'query': body}).encode(), headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json', 'User-Agent': 'curl/8'})
try: urllib.request.urlopen(req, timeout=600).read(); print('想定外'); sys.exit(2)
except urllib.error.HTTPError as e: raw = e.read().decode()
msg = json.loads(raw).get('message', raw); m = re.search(r'#DEP#(\{.*\})', msg, re.S)
if not m: print(msg[:2500]); sys.exit(1)
res = json.loads(m.group(1))
print('権限漏れ修正のリハーサル（実環境・巻き戻し済み）')
for k, v in res.items(): print(k, json.dumps(v, ensure_ascii=False)[:1500])
