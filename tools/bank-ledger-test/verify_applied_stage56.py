#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""段階5・6 適用後の確認（本番・読み取りと、必ず巻き戻す PayPay 取込の試し）。実ユーザーの権限（JWTの sub を設定）で、見え方・所要時間を測る。"""
import json, os, re, sys, urllib.request, urllib.error
pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
body = r"""
do $__r__$
declare u record; res jsonb := '[]'::jsonb; t0 timestamptz; n bigint; a bigint; b bigint; c bigint; d bigint; e bigint; ms numeric; acct uuid; imp uuid; hex text := repeat('e', 64); b1 uuid; run jsonb; out jsonb := '{}'::jsonb;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  for u in select id, name, role, is_master, (select count(*) from info.user_corporations x where x.user_id = users.id) lim from public.users where is_active and (role in ('CEO','HQ') or is_master) order by role, name loop
    perform set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true);
    set local role authenticated;
    t0 := clock_timestamp();
    select count(*) into a from public.bank_transactions; select count(*) into b from public.bank_accounts; select count(*) into c from storage.objects where bucket_id = 'bank-csv-originals'; select count(*) into d from public.bank_deposit_daily(); select count(*) into e from public.bank_legacy_rows;
    ms := extract(epoch from clock_timestamp() - t0) * 1000;
    res := res || jsonb_build_object('role', u.role, 'master', u.is_master, 'corp_limited', u.lim > 0, 'global_admin', public.bank_global_admin(), 'tx', a, 'accts', b, 'originals', c, 'daily_rows', d, 'legacy_rows', e, 'ms', round(ms));
    reset role;
  end loop;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  out := out || jsonb_build_object('users', res);
  -- PayPay 取込・照合（サービスロール）の試し → 巻き戻す
  acct := public.bank_account_upsert('paypay', 'verify56', 'VERIFY-0000001', '適用後確認', null);
  insert into storage.objects (bucket_id, name, metadata) values ('bank-csv-originals', 'paypay/' || acct || '/' || hex || '.csv', '{"size": 10}');
  imp := public.bank_import_register(acct, 'playwright', 'verify.csv', date '2026-11-27', date '2026-11-27');
  perform public.bank_import_attach_original(imp, hex, 10, 'text/csv'); perform public.bank_import_record_verification(imp, hex, 10);
  perform public.bank_import_ingest(imp, '[{"date":"2026-11-27","time":"10:00:00","desc":"ATM verify","dep":4321,"wd":0,"bal":1,"key":"verify|1","basis":"seq_no"}]'::jsonb, true);
  perform public.bank_import_commit(imp);
  select id into b1 from public.bank_legacy_batches order by created_at limit 1;
  run := public.bank_reconcile_run(b1, null, (now() at time zone 'Asia/Tokyo')::date);
  out := out || jsonb_build_object('paypay_ingest_ok', exists (select 1 from public.bank_transactions where bank_account_id = acct and match_status = 'verified'), 'reconcile_status', run ->> 'status');
  raise exception '#V56#%', out::text;
end $__r__$;
"""
req = urllib.request.Request('https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query', data=json.dumps({'query': body}).encode(), headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json', 'User-Agent': 'curl/8'})
try: urllib.request.urlopen(req, timeout=300).read(); print('想定外')
except urllib.error.HTTPError as e: raw = e.read().decode()
msg = json.loads(raw).get('message', raw); m = re.search(r'#V56#(\{.*\})', msg, re.S)
if not m: print(msg[:1500]); sys.exit(1)
o = json.loads(m.group(1))
for u in o['users']: print(u)
print('paypay_ingest_ok', o['paypay_ingest_ok'], 'reconcile_status', o['reconcile_status'])
