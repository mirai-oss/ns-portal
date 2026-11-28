#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""段階6（法人別の閲覧・操作）の実環境リハーサル: 段階5→段階6のSQLを中で流し、ロールを authenticated に切り替えて
   各人の見え方（適用前後）を測り、ロールバックSQLも流して元に戻ることを確かめ、最後に必ず例外で巻き戻す（本番には何も残らない）。
   段階5・6が本番に未適用の状態で動く（段階5は中で流す）。
  python3 tools/bank-ledger-test/rehearsal_stage6.py
"""
import json, os, re, sys, time, urllib.request, urllib.error
HERE = os.path.dirname(os.path.abspath(__file__))
rd = lambda n: open(os.path.join(HERE, '..', '..', 'supabase', n), encoding='utf-8').read()
S5, S6, RB6 = rd('2026-11-28_bank_ledger_stage5.sql'), rd('2026-11-28_bank_ledger_stage6.sql'), rd('2026-11-28_bank_ledger_stage6_ROLLBACK.sql')
body = r"""
do $__r__$
declare
  s5 text := $__s5__$__S5__$__s5__$;
  s6 text := $__s6__$__S6__$__s6__$;
  rb6 text := $__rb6__$__RB6__$__rb6__$;
  res jsonb := '{}'::jsonb; u record; sig_before jsonb := '{}'::jsonb; sig_after jsonb := '{}'::jsonb; sig_rb jsonb := '{}'::jsonb;
  fp0 jsonb; n_tx int; pol0 text; pol1 text; fun0 text; fun1 text;
  function_sig text;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  fp0 := public.bank_csv_rows_fingerprint(); select count(*) into n_tx from public.bank_transactions;
  execute s5;
  select md5(coalesce(string_agg(tablename || policyname || coalesce(qual, '') || coalesce(with_check, ''), '|' order by schemaname, tablename, policyname), '')) into pol0 from pg_policies where tablename like 'bank\_%' or policyname like 'bank%';
  select md5(coalesce(string_agg(pg_get_functiondef(p.oid), '|' order by p.proname, pg_get_function_identity_arguments(p.oid)), '')) into fun0 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'bank\_%' and p.prokind = 'f';
  -- 各人の見え方を測る関数（authenticated になって数える）
  create temporary table _sig (phase text, uid uuid, role text, txs int, accts int, origs int, imps int, evs int, objs int, daily_rows int, daily_amount numeric, legacy int, diffs int, status_rows int, notes int) on commit drop;
  grant insert on _sig to authenticated;
  for u in select id, role from (select id, role, row_number() over (partition by role, exists (select 1 from info.user_corporations x where x.user_id = users.id) order by id) rn from public.users where is_active and role in ('CEO', 'HQ', 'TEAM', 'TENCHO', 'SHAIN')) q where rn <= 2 order by role, id loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true);
    set local role authenticated;
    insert into _sig select 'A', u.id, u.role, (select count(*) from public.bank_transactions), (select count(*) from public.bank_accounts), (select count(*) from public.bank_csv_originals),
        (select count(*) from public.bank_import_files), (select count(*) from public.bank_transaction_events), (select count(*) from storage.objects where bucket_id = 'bank-csv-originals'),
        (select count(*) from public.bank_deposit_daily()), (select coalesce(sum(amount), 0) from public.bank_deposit_daily()),
        (select count(*) from public.bank_legacy_rows), (select count(*) from public.bank_diff_items), (select count(*) from public.bank_sync_status()), (select count(*) from public.bank_deposit_notes);
    reset role;
  end loop;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  execute s6;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  for u in select id, role from (select id, role, row_number() over (partition by role, exists (select 1 from info.user_corporations x where x.user_id = users.id) order by id) rn from public.users where is_active and role in ('CEO', 'HQ', 'TEAM', 'TENCHO', 'SHAIN')) q where rn <= 2 order by role, id loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true);
    set local role authenticated;
    insert into _sig select 'B', u.id, u.role, (select count(*) from public.bank_transactions), (select count(*) from public.bank_accounts), (select count(*) from public.bank_csv_originals),
        (select count(*) from public.bank_import_files), (select count(*) from public.bank_transaction_events), (select count(*) from storage.objects where bucket_id = 'bank-csv-originals'),
        (select count(*) from public.bank_deposit_daily()), (select coalesce(sum(amount), 0) from public.bank_deposit_daily()),
        (select count(*) from public.bank_legacy_rows), (select count(*) from public.bank_diff_items), (select count(*) from public.bank_sync_status()), (select count(*) from public.bank_deposit_notes);
    reset role;
  end loop;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  -- 適用前後で数が変わった人だけ（法人を限定された人のはず）
  res := res || jsonb_build_object('changed_users', (select coalesce(jsonb_agg(jsonb_build_object('role', a.role, 'limited_in_info', exists (select 1 from info.user_corporations x where x.user_id = a.uid) or exists (select 1 from info.profiles p join info.role_corporations rc on rc.role_id = p.role_id where p.id = a.uid),
        'tx_before', a.txs, 'tx_after', b.txs, 'acct_before', a.accts, 'acct_after', b.accts, 'objs_before', a.objs, 'objs_after', b.objs, 'daily_before', a.daily_rows, 'daily_after', b.daily_rows, 'legacy_before', a.legacy, 'legacy_after', b.legacy)), '[]'::jsonb)
      from _sig a join _sig b on a.uid = b.uid and a.phase = 'A' and b.phase = 'B' where (a.txs, a.accts, a.origs, a.imps, a.evs, a.objs, a.daily_rows, a.daily_amount, a.legacy, a.diffs, a.status_rows, a.notes) is distinct from (b.txs, b.accts, b.origs, b.imps, b.evs, b.objs, b.daily_rows, b.daily_amount, b.legacy, b.diffs, b.status_rows, b.notes)),
    'users_measured', (select count(*) from _sig where phase = 'A'),
    'unchanged_users', (select count(*) from _sig a join _sig b on a.uid = b.uid and a.phase = 'A' and b.phase = 'B' where (a.txs, a.accts, a.origs, a.imps, a.evs, a.objs, a.daily_rows, a.daily_amount, a.legacy, a.diffs, a.status_rows, a.notes) is not distinct from (b.txs, b.accts, b.origs, b.imps, b.evs, b.objs, b.daily_rows, b.daily_amount, b.legacy, b.diffs, b.status_rows, b.notes)),
    'global_admin_view', (select jsonb_agg(jsonb_build_object('role', role, 'tx', txs, 'daily', daily_rows)) from _sig where phase = 'B' and role in ('CEO')));
  -- 不変の確認
  res := res || jsonb_build_object('tx_count_unchanged', n_tx = (select count(*) from public.bank_transactions), 'csv_rows_unchanged', fp0 = public.bank_csv_rows_fingerprint());
  -- ロールバック（段階6）で元に戻る
  execute rb6;
  select md5(coalesce(string_agg(tablename || policyname || coalesce(qual, '') || coalesce(with_check, ''), '|' order by schemaname, tablename, policyname), '')) into pol1 from pg_policies where tablename like 'bank\_%' or policyname like 'bank%';
  select md5(coalesce(string_agg(pg_get_functiondef(p.oid), '|' order by p.proname, pg_get_function_identity_arguments(p.oid)), '')) into fun1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname like 'bank\_%' and p.prokind = 'f';
  res := res || jsonb_build_object('rollback_policies_identical', pol0 = pol1, 'rollback_functions_identical', fun0 = fun1);
  raise exception '#REH6#%', res::text;
end
$__r__$;
"""
body = body.replace('__S5__', S5).replace('__S6__', S6).replace('__RB6__', RB6)
for t in ('$__s5__$', '$__s6__$', '$__rb6__$', '$__r__$'): assert t not in S5 + S6 + RB6
pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
req = urllib.request.Request('https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query', data=json.dumps({'query': body}).encode(), headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json', 'User-Agent': 'curl/8'})
try:
    urllib.request.urlopen(req, timeout=600).read(); print('想定外: 例外で終わらず成功'); sys.exit(2)
except urllib.error.HTTPError as e:
    raw = e.read().decode()
try: msg = json.loads(raw).get('message', raw)
except Exception: msg = raw
m = re.search(r'#REH6#(\{.*\})', msg, re.S)
if not m: print('失敗:'); print(msg[:3000]); sys.exit(1)
res = json.loads(m.group(1))
json.dump(res, open(os.path.join(HERE, '..', '..', 'local-private', 'rehearsal6_%s.json' % time.strftime('%Y%m%d-%H%M%S')), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print('段階6リハーサル完了（巻き戻し済み）')
for k, v in res.items(): print(k, json.dumps(v, ensure_ascii=False)[:900])
