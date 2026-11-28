#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""段階5（店舗未確定の管理・運営法人の履歴）の実環境リハーサル: 段階5のSQLを中で流し、使い捨ての口座・明細で
   紐付け・取り消し・権限・運営法人の履歴を確かめて、必ず例外で巻き戻す（本番には何も残らない）。
  python3 tools/bank-ledger-test/rehearsal_stage5.py
"""
import json, os, re, sys, time, urllib.request, urllib.error
HERE = os.path.dirname(os.path.abspath(__file__))
S5 = open(os.path.join(HERE, '..', '..', 'supabase', '2026-11-28_bank_ledger_stage5.sql'), encoding='utf-8').read()
RB = open(os.path.join(HERE, '..', '..', 'supabase', '2026-11-28_bank_ledger_stage5_ROLLBACK.sql'), encoding='utf-8').read()
body = r"""
do $__r__$
declare
  s5 text := $__s5__$__S5__$__s5__$;
  rb text := $__rb__$__RB__$__rb__$;
  ceo uuid; st1 uuid; st2 uuid; c1 uuid; c2 uuid; ac uuid; acm uuid; t1 uuid; t2 uuid; t3 uuid; t4 uuid;
  res jsonb := '{}'::jsonb; fp0 jsonb; fp1 jsonb; dd0 text; dd1 text; n0 int; n1 int; r jsonb; hid uuid; denied int := 0; ok boolean;
  nstores int; nperiods int; leak int := 0; w text;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select id into ceo from public.users where role = 'CEO' and is_active limit 1;
  if ceo is null then raise exception 'CEO ユーザーが見つかりません'; end if;
  fp0 := public.bank_csv_rows_fingerprint(); select count(*) into n0 from public.bank_transactions;
  select md5(coalesce(string_agg(x::text, '|' order by x::text), '')) into dd0 from public.bank_deposit_daily() x;
  execute s5;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select count(*) into nstores from public.stores where corporation_id is not null; select count(*) into nperiods from public.store_corporation_periods;
  res := res || jsonb_build_object('stores_with_corp', nstores, 'initial_periods', nperiods, 'periods_equal_stores', nstores = nperiods);
  select md5(coalesce(string_agg(x::text, '|' order by x::text), '')) into dd1 from public.bank_deposit_daily() x;
  fp1 := public.bank_csv_rows_fingerprint(); select count(*) into n1 from public.bank_transactions;
  res := res || jsonb_build_object('daily_unchanged_after_apply', dd0 = dd1, 'csv_rows_unchanged', fp0 = fp1, 'tx_count_unchanged', n0 = n1);
  -- 使い捨てデータ
  select s.id, s.corporation_id into st1, c1 from public.stores s where s.corporation_id is not null order by s.name limit 1;
  select s.id, s.corporation_id into st2, c2 from public.stores s where s.corporation_id is not null and s.corporation_id <> c1 order by s.name limit 1;
  if st2 is null then select s.id, s.corporation_id into st2, c2 from public.stores s where s.corporation_id is not null and s.id <> st1 order by s.name limit 1; end if;
  insert into public.bank_accounts (bank_code, login_group, account_no, display_name) values ('gmo_aozora', 'rehearsal5', 'RH5-0000001', '段階5リハーサル') returning id into ac;
  insert into public.bank_accounts (bank_code, login_group, account_no, display_name, usage_mode) values ('gmo_aozora', 'rehearsal5', 'RH5-0000002', '段階5リハーサル共有', 'multi') returning id into acm;
  insert into public.bank_transactions (bank_account_id, txn_date, description, deposit_amount, source_kind, dedupe_key, match_status, tx_kind, counts_as_sales_deposit)
    values (ac, date '2026-11-01', 'RH5', 1111, 'manual_entry', 'rh5-1', 'verified', 'atm_deposit', true) returning id into t1;
  insert into public.bank_transactions (bank_account_id, txn_date, description, deposit_amount, source_kind, dedupe_key, match_status, tx_kind, counts_as_sales_deposit, confirm_status, confirmed_at)
    values (ac, date '2026-11-02', 'RH5', 2222, 'manual_entry', 'rh5-2', 'verified', 'atm_deposit', true, 'confirmed', now()) returning id into t2;
  insert into public.bank_transactions (bank_account_id, txn_date, description, deposit_amount, source_kind, dedupe_key, match_status, tx_kind, counts_as_sales_deposit)
    values (acm, date '2026-11-03', 'RH5', 3333, 'manual_entry', 'rh5-3', 'verified', 'atm_deposit', true) returning id into t3;
  select count(*) into n0 from public.bank_deposit_daily() where store_id = st1 and amount in (1111, 2222, 3333);
  res := res || jsonb_build_object('unassigned_not_counted', n0 = 0);
  -- 権限: 管理者以外は拒否（アクティブな店長・社員を 1 人ずつ）
  for w in select u.id::text from public.users u where u.is_active and not coalesce(u.is_master, false) and u.role not in ('CEO', 'HQ') order by u.id limit 3 loop
    perform set_config('request.jwt.claims', json_build_object('sub', w, 'role', 'authenticated')::text, true);
    begin perform public.bank_account_assign_store(ac, st1, 'x'); leak := leak + 1; exception when others then null; end;
    begin perform public.store_corporation_change(st1, c2, date '2030-01-01', 'x'); leak := leak + 1; exception when others then null; end;
    if exists (select 1 from public.bank_unassigned_summary()) then leak := leak + 1; end if;
    if exists (select 1 from public.bank_unassigned_list(ac)) then leak := leak + 1; end if;
  end loop;
  res := res || jsonb_build_object('non_admin_leaks', leak);
  perform set_config('request.jwt.claims', json_build_object('sub', ceo, 'role', 'authenticated')::text, true);
  res := res || jsonb_build_object('summary_rows_for_admin', (select count(*) from public.bank_unassigned_summary()),
                                   'summary_has_test_account', exists (select 1 from public.bank_unassigned_summary() s where s.account_id = ac and s.unassigned_count = 2));
  r := public.bank_account_assign_store(ac, st1, 'リハーサル');
  res := res || jsonb_build_object('assign', r, 'tx1_assigned', (select store_id = st1 from public.bank_transactions where id = t1), 'tx2_confirmed_untouched', (select store_id is null from public.bank_transactions where id = t2));
  select count(*) into n0 from public.bank_deposit_daily() where store_id = st1 and deposit_date = date '2026-11-01' and amount >= 1111;
  res := res || jsonb_build_object('flows_into_daily', n0 > 0);
  select id into hid from public.bank_assignment_history where kind = 'account' and account_id = ac and action = 'assign';
  r := public.bank_assignment_revert(hid, 'リハーサルの取り消し');
  res := res || jsonb_build_object('revert', r, 'tx1_back_to_null', (select store_id is null from public.bank_transactions where id = t1), 'account_back', (select store_status = 'unassigned' from public.bank_accounts where id = ac));
  r := public.bank_tx_assign_store(array[t3], st2, '共有口座の取引単位', false);
  res := res || jsonb_build_object('shared_tx_assign', r, 'shared_account_has_no_store', (select store_id is null from public.bank_accounts where id = acm));
  begin perform public.bank_account_assign_store(acm, st1, 'x'); res := res || jsonb_build_object('multi_account_blocked', false); exception when others then res := res || jsonb_build_object('multi_account_blocked', true); end;
  r := public.store_corporation_change(st1, c2, date '2099-01-01', 'リハーサル（巻き戻す）');
  res := res || jsonb_build_object('corp_change', r, 'past_unchanged', public.store_corporation_on(st1, date '2026-11-30') = c1, 'future_changed', public.store_corporation_on(st1, date '2099-01-02') = c2);
  -- 段階5のロールバックは、履歴・人が足した期間があるので止まる
  begin execute rb; res := res || jsonb_build_object('rollback_stops_with_data', false); exception when others then res := res || jsonb_build_object('rollback_stops_with_data', true); end;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  res := res || jsonb_build_object('csv_rows_unchanged_end', fp0 = public.bank_csv_rows_fingerprint());
  raise exception '#REH5#%', res::text;
end
$__r__$;
"""
body = body.replace('__S5__', S5).replace('__RB__', RB)
for t in ('$__s5__$', '$__rb__$', '$__r__$'): assert t not in S5 and t not in RB
pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
req = urllib.request.Request('https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query', data=json.dumps({'query': body}).encode(), headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json', 'User-Agent': 'curl/8'})
try:
    urllib.request.urlopen(req, timeout=600).read(); print('想定外: 例外で終わらず成功'); sys.exit(2)
except urllib.error.HTTPError as e:
    raw = e.read().decode()
try: msg = json.loads(raw).get('message', raw)
except Exception: msg = raw
m = re.search(r'#REH5#(\{.*\})', msg, re.S)
if not m: print('失敗:'); print(msg[:2500]); sys.exit(1)
res = json.loads(m.group(1))
json.dump(res, open(os.path.join(HERE, '..', '..', 'local-private', 'rehearsal5_%s.json' % time.strftime('%Y%m%d-%H%M%S')), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print('段階5リハーサル完了（巻き戻し済み）')
for k, v in res.items(): print(k, json.dumps(v, ensure_ascii=False)[:300])
