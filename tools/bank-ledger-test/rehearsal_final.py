#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""段階5・6 本番適用前の最終検証（実環境で流して必ず巻き戻す）。
  A=適用前 → 段階5だけ(M) → 段階6(B) の 3 時点で各人の見え方を測り、PayPay取込・照合（サービスロール）が動くこと、各画面相当の問い合わせの所要時間、
  段階6→段階5 のロールバックで元（A）と完全に一致することを確かめる。最後に必ず例外で巻き戻す（本番には何も残らない）。
  python3 tools/bank-ledger-test/rehearsal_final.py
"""
import json, os, re, sys, time, urllib.request, urllib.error
HERE = os.path.dirname(os.path.abspath(__file__))
rd = lambda n: open(os.path.join(HERE, '..', '..', 'supabase', n), encoding='utf-8').read()
S5, S6, RB5, RB6 = rd('2026-11-28_bank_ledger_stage5.sql'), rd('2026-11-28_bank_ledger_stage6.sql'), rd('2026-11-28_bank_ledger_stage5_ROLLBACK.sql'), rd('2026-11-28_bank_ledger_stage6_ROLLBACK.sql')
MEASURE = """
    insert into _sig select '%PH%', u.id, u.role, (select count(*) from public.bank_transactions), (select count(*) from public.bank_accounts), (select count(*) from public.bank_csv_originals),
        (select count(*) from public.bank_import_files), (select count(*) from public.bank_transaction_events), (select count(*) from storage.objects where bucket_id = 'bank-csv-originals'),
        (select count(*) from public.bank_deposit_daily()), 0,
        (select count(*) from public.bank_legacy_rows), (select count(*) from public.bank_diff_items), (select count(*) from public.bank_sync_status()), (select count(*) from public.bank_deposit_notes), 0, 0;
"""
LOOP = """  for u in select id, role from _users order by role, id loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true);
    set local role authenticated;
%M%
    reset role;
  end loop;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
"""
def phase(ph): return LOOP.replace('%M%', MEASURE.replace('%PH%', ph))
body = r"""
do $__r__$
declare
  s5 text := $__s5__$__S5__$__s5__$; s6 text := $__s6__$__S6__$__s6__$; rb5 text := $__rb5__$__RB5__$__rb5__$; rb6 text := $__rb6__$__RB6__$__rb6__$;
  res jsonb := '{}'::jsonb; u record; ex0 text; ex1 text; fp0 jsonb; n_tx int; pol0 text; pol1 text; fun0 text; fun1 text; tb0 text; tb1 text; col0 text; col1 text;
  acct uuid; imp uuid; hex text := repeat('f', 64); b1 uuid; run jsonb; rep jsonb; t0 timestamptz; dsvc int; cnt_after int; ms jsonb := '[]'::jsonb; n bigint; v numeric;
  cur_policy text := $q$select md5(coalesce(string_agg(tablename || policyname || coalesce(qual, '') || coalesce(with_check, ''), '|' order by schemaname, tablename, policyname), '')) from pg_policies where tablename like 'bank\_%' or policyname like 'bank%'$q$;
  cur_fun text := $q$select md5(coalesce(string_agg(pg_get_functiondef(p.oid), '|' order by p.proname, pg_get_function_identity_arguments(p.oid)), '')) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'bank\_%' and p.prokind = 'f'$q$;
  cur_exist text := $q$select md5(
      (select coalesce(string_agg(pg_get_functiondef(p.oid), '|' order by p.proname, pg_get_function_identity_arguments(p.oid)), '') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
         and p.proname <> all (array['bank_unassigned_summary','bank_unassigned_list','bank_account_assign_store','bank_tx_assign_store','bank_assignment_revert','store_corporation_on','store_corporation_change','bank_ledger_global_set','bank_corp_ok','bank_allowed_corp_ids','bank_global_admin','store_corp_periods_guard','bank_ledger_global_guard']))
      || (select coalesce(string_agg(tablename || policyname || coalesce(qual, '') || coalesce(with_check, ''), '|' order by schemaname, tablename, policyname), '') from pg_policies where tablename <> all (array['store_corporation_periods','bank_assignment_history','bank_ledger_global_users']))
      || (select coalesce(string_agg(table_name || column_name || data_type || coalesce(column_default, ''), '|' order by table_name, column_name), '') from information_schema.columns where table_schema = 'public' and not (table_name = 'bank_accounts' and column_name = 'usage_mode') and table_name <> all (array['store_corporation_periods','bank_assignment_history','bank_ledger_global_users']))
      || (select coalesce(string_agg(grantee || table_name || privilege_type, '|' order by grantee, table_name, privilege_type), '') from information_schema.role_table_grants where table_schema = 'public' and table_name <> all (array['store_corporation_periods','bank_assignment_history','bank_ledger_global_users']))
    )$q$;
  cur_tab text := $q$select md5(coalesce(string_agg(relname, '|' order by relname), '')) from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r'$q$;
  cur_col text := $q$select md5(coalesce(string_agg(table_name || column_name || data_type, '|' order by table_name, column_name), '')) from information_schema.columns where table_schema = 'public'$q$;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  fp0 := public.bank_csv_rows_fingerprint(); select count(*) into n_tx from public.bank_transactions;
  execute cur_policy into pol0; execute cur_fun into fun0; execute cur_tab into tb0; execute cur_col into col0;
  create temporary table _sig (phase text, uid uuid, role text, txs int, accts int, origs int, imps int, evs int, objs int, daily_rows int, daily_amount numeric, legacy int, diffs int, status_rows int, notes int, x1 int, x2 int) on commit drop;
  grant insert on _sig to authenticated;
  create temporary table _users as select id, role from (select id, role, row_number() over (partition by role, exists (select 1 from info.user_corporations x where x.user_id = users.id) order by id) rn from public.users where is_active and role in ('CEO', 'HQ', 'TEAM', 'TENCHO', 'SHAIN')) q where rn <= 2;
  grant select on _users to authenticated;
__PA__
  execute cur_exist into ex0;
  execute s5;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute cur_exist into ex1;
  res := res || jsonb_build_object('stage5_existing_objects_unchanged', ex0 = ex1);
  execute s6;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
__PB__
  -- 比較
  res := res || jsonb_build_object('users_measured', (select count(*) from _sig where phase = 'A'),
    'stage6_changed', (select coalesce(jsonb_agg(jsonb_build_object('role', a.role, 'limited', exists (select 1 from info.user_corporations x where x.user_id = a.uid), 'granted', exists (select 1 from public.bank_ledger_global_users g where g.user_id = a.uid and g.revoked_at is null),
        'tx', a.txs || '->' || b.txs, 'acct', a.accts || '->' || b.accts, 'orig', a.origs || '->' || b.origs, 'objs', a.objs || '->' || b.objs, 'daily', a.daily_rows || '->' || b.daily_rows, 'legacy', a.legacy || '->' || b.legacy)), '[]'::jsonb)
      from _sig a join _sig b on a.uid = b.uid and a.phase = 'A' and b.phase = 'B' where (a.txs, a.accts, a.origs, a.imps, a.evs, a.objs, a.daily_rows, a.legacy, a.diffs, a.status_rows, a.notes) is distinct from (b.txs, b.accts, b.origs, b.imps, b.evs, b.objs, b.daily_rows, b.legacy, b.diffs, b.status_rows, b.notes)),
    'stage6_unchanged_users', (select count(*) from _sig a join _sig b on a.uid = b.uid and a.phase = 'A' and b.phase = 'B' where (a.txs, a.accts, a.origs, a.imps, a.evs, a.objs, a.daily_rows, a.legacy, a.diffs, a.status_rows, a.notes) is not distinct from (b.txs, b.accts, b.origs, b.imps, b.evs, b.objs, b.daily_rows, b.legacy, b.diffs, b.status_rows, b.notes)),
    'global_grants_seeded', (select count(*) from public.bank_ledger_global_users where revoked_at is null),
    'hq_active_total', (select count(*) from public.users where is_active and role = 'HQ'),
    'hq_limited_by_info', (select count(*) from public.users hu where hu.is_active and hu.role = 'HQ' and exists (select 1 from info.user_corporations x where x.user_id = hu.id)));
  -- 所要時間（段階6適用後・各画面相当の問い合わせ。ミリ秒）
  for u in select id, role from (select id, role, row_number() over (partition by role, exists (select 1 from info.user_corporations x where x.user_id = users.id) order by id) rn from public.users where is_active and role in ('CEO', 'HQ', 'TEAM', 'TENCHO')) q where rn = 1 order by role, id loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true);
    set local role authenticated;
    t0 := clock_timestamp(); select count(*) into n from (select * from public.bank_transactions order by txn_date desc limit 1000) x; ms := ms || jsonb_build_object('role', u.role, 'q', 'tx1000', 'ms', round(extract(epoch from clock_timestamp() - t0) * 1000));
    t0 := clock_timestamp(); select count(*) into n from public.bank_deposit_daily(); ms := ms || jsonb_build_object('role', u.role, 'q', 'daily', 'ms', round(extract(epoch from clock_timestamp() - t0) * 1000));
    t0 := clock_timestamp(); select count(*) into n from public.bank_sync_status(); ms := ms || jsonb_build_object('role', u.role, 'q', 'sync', 'ms', round(extract(epoch from clock_timestamp() - t0) * 1000));
    t0 := clock_timestamp(); select count(*) into n from public.bank_unassigned_summary(); ms := ms || jsonb_build_object('role', u.role, 'q', 'unassigned', 'ms', round(extract(epoch from clock_timestamp() - t0) * 1000));
    t0 := clock_timestamp(); select count(*) into n from storage.objects where bucket_id = 'bank-csv-originals'; ms := ms || jsonb_build_object('role', u.role, 'q', 'storage', 'ms', round(extract(epoch from clock_timestamp() - t0) * 1000));
    reset role;
  end loop;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  res := res || jsonb_build_object('timings_ms', ms, 'max_ms', (select max((x ->> 'ms')::int) from jsonb_array_elements(ms) x));
  -- PayPay 取込（サービスロール）: 使い捨ての口座・原本・明細 → 日次集計に出る → 照合も動く
  acct := public.bank_account_upsert('paypay', 'final_check', 'FINAL-0000001', '最終検証', null);
  insert into storage.objects (bucket_id, name, metadata) values ('bank-csv-originals', 'paypay/' || acct || '/' || hex || '.csv', '{"size": 10}');
  imp := public.bank_import_register(acct, 'playwright', 'final.csv', date '2026-11-27', date '2026-11-27');
  perform public.bank_import_attach_original(imp, hex, 10, 'text/csv'); perform public.bank_import_record_verification(imp, hex, 10);
  perform public.bank_import_ingest(imp, '[{"date":"2026-11-27","time":"10:00:00","desc":"ATM final","dep":1234,"wd":0,"bal":1,"key":"final|1","basis":"seq_no"}]'::jsonb, true);
  perform public.bank_import_commit(imp);
  res := res || jsonb_build_object('service_ingest_ok', exists (select 1 from public.bank_transactions where bank_account_id = acct and deposit_amount = 1234 and match_status = 'verified'),
     'service_sees_all_tx', (select count(*) from public.bank_transactions) = n_tx + 1);
  select id into b1 from public.bank_legacy_batches order by created_at limit 1;
  run := public.bank_reconcile_run(b1, null, (now() at time zone 'Asia/Tokyo')::date);
  rep := public.bank_reconcile_report(14);
  res := res || jsonb_build_object('service_reconcile_ran', run is not null, 'reconcile_status', run ->> 'status', 'reconcile_nontiming_mismatch', run -> 'nontiming_mismatches', 'report_days', rep -> 'days_observed');
  -- ロールバック（段階6 → 段階5）で、ポリシー・関数・表・列が適用前と完全に一致
  execute rb6; execute rb5;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute cur_policy into pol1; execute cur_fun into fun1; execute cur_tab into tb1; execute cur_col into col1;
  res := res || jsonb_build_object('rollback_policies_identical', pol0 = pol1, 'rollback_functions_identical', fun0 = fun1, 'rollback_tables_identical', tb0 = tb1, 'rollback_columns_identical', col0 = col1);
  raise exception '#FINAL#%', res::text;
end
$__r__$;
"""
body = body.replace('__PA__', phase('A')).replace('__PM__', phase('M')).replace('__PB__', phase('B'))
body = body.replace('__S5__', S5).replace('__S6__', S6).replace('__RB5__', RB5).replace('__RB6__', RB6)
for t in ('$__s5__$', '$__s6__$', '$__rb5__$', '$__rb6__$', '$__r__$'): assert t not in S5 + S6 + RB5 + RB6
pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
req = urllib.request.Request('https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query', data=json.dumps({'query': body}).encode(), headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json', 'User-Agent': 'curl/8'})
try:
    urllib.request.urlopen(req, timeout=900).read(); print('想定外: 例外で終わらず成功'); sys.exit(2)
except urllib.error.HTTPError as e:
    raw = e.read().decode()
try: msg = json.loads(raw).get('message', raw)
except Exception: msg = raw
m = re.search(r'#FINAL#(\{.*\})', msg, re.S)
if not m: print('失敗:'); print(msg[:3000]); sys.exit(1)
res = json.loads(m.group(1))
json.dump(res, open(os.path.join(HERE, '..', '..', 'local-private', 'rehearsal_final_%s.json' % time.strftime('%Y%m%d-%H%M%S')), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print('最終検証（実環境・巻き戻し済み）')
for k, v in res.items(): print(k, json.dumps(v, ensure_ascii=False)[:700])
