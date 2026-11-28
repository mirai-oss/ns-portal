#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""段階4（毎日の照合）の実データのリハーサル: 段階4のSQLを中で流し、①今日の取り出し（移行済みと同じ内容）の照合 ②翌日を想定した変化（旧行の追加・削除・修正）の検出 を流して、必ず巻き戻す。
  python3 tools/bank-ledger-test/rehearsal_stage4.py <payload.json>      本番には何も残らない（最後に必ず例外で終わる）
"""
import json, os, re, sys, time, urllib.request, urllib.error, copy
HERE = os.path.dirname(os.path.abspath(__file__))
S4 = open(os.path.join(HERE, '..', '..', 'supabase', '2026-11-28_bank_ledger_stage4.sql'), encoding='utf-8').read()
payload = json.load(open(sys.argv[1], encoding='utf-8'))
rows2 = copy.deepcopy(payload['rows'])
# 翌日を想定した変化: ①ATM の旧行を 1 行削除（期間前の行）②旧行を 1 行追加（今日付・銀行の期間内・まだ銀行側に無い）③手動調整の金額を 1 件修正
today = time.strftime('%Y-%m-%d', time.gmtime(time.time() + 9 * 3600))
rm = next(i for i, r in enumerate(rows2) if r['date'] < '2026-08-01' and r['store_id'] and not r['desc'].startswith(('調整', 'sss')) and r['amount'] > 0)
removed = rows2.pop(rm)
store_with_acct = next(r for r in rows2 if r['store'] == '鳥一代 新橋')
rows2.append({'row_no': max(r['row_no'] for r in rows2) + 1, 'store': store_with_acct['store'], 'store_id': store_with_acct['store_id'], 'date': today, 'amount': 12345, 'desc': 'ATM セブン銀行', 'token': '12:34:56', 'registered_at': today + 'T12:40:00+09:00'})
am = next(i for i, r in enumerate(rows2) if r['desc'] == '調整分' and 0 < r['amount'] < 3000000)
rows2[am]['amount'] += 500
for i, r in enumerate(rows2): r['row_no'] = i + 3   # 並べ替え後の行番号（同一性は内容＋出現番号なので影響しない）
meta2 = dict(payload['meta']); import hashlib; meta2['payload_sha256'] = hashlib.sha256(('day2|' + payload['meta']['payload_sha256']).encode()).hexdigest()
body = r"""
do $__r__$
declare
  s4 text := $__s4__$__S4__$__s4__$;
  r2 jsonb := $__m__$__ROWS2__$__m__$;
  meta2 jsonb := '__META2__'::jsonb;
  b1 uuid; b2 uuid; run1 jsonb; run2 jsonb; rep jsonb; res jsonb := '{}'::jsonb; fp0 jsonb; fp1 jsonb; n1 int; n2 int;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  select id into b1 from public.bank_legacy_batches order by created_at limit 1;
  if b1 is null then raise exception '移行済みのバッチがありません'; end if;
  fp0 := public.bank_csv_rows_fingerprint(); select count(*) into n1 from public.bank_transactions;
  execute s4;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  run1 := public.bank_reconcile_run(b1, null, (now() at time zone 'Asia/Tokyo')::date);
  res := res || jsonb_build_object('day1', run1);
  b2 := public.bank_legacy_load(meta2, r2, '[]'::jsonb);
  run2 := public.bank_reconcile_run(b2, b1, (now() at time zone 'Asia/Tokyo')::date + 1);
  res := res || jsonb_build_object('day2', run2,
     'day2_open_mismatches', (select jsonb_agg(jsonb_build_object('date', m.txn_date, 'cause', m.cause, 'timing', m.is_timing, 'legacy_count', m.legacy_count, 'ledger_count', m.ledger_count)) from public.bank_reconcile_mismatches m where m.status = 'open'),
     'diff_items', (select jsonb_object_agg(kind || '/' || status, c) from (select kind, status, count(*) c from public.bank_diff_items group by 1, 2) q),
     'report', public.bank_reconcile_report(14),
     'csv_rows_unchanged', fp0 = public.bank_csv_rows_fingerprint(), 'bank_tx_before', n1, 'bank_tx_after', (select count(*) from public.bank_transactions),
     'manual_adjustment_open', (select count(*) from public.bank_diff_items where kind = 'manual_adjustment' and status = 'open'),
     'ambiguous_open', (select count(*) from public.bank_diff_items where kind = 'ambiguous_pair' and status = 'open'));
  raise exception '#REH4#%', res::text;
end
$__r__$;
"""
body = body.replace('__S4__', S4).replace('__ROWS2__', json.dumps(rows2, ensure_ascii=False)).replace('__META2__', json.dumps(meta2, ensure_ascii=False).replace("'", "''"))
for t in ('$__s4__$', '$__m__$', '$__r__$'): assert t not in S4
pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
req = urllib.request.Request('https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query', data=json.dumps({'query': body}).encode(), headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json', 'User-Agent': 'curl/8'})
try:
    urllib.request.urlopen(req, timeout=600).read(); print('想定外: 例外で終わらず成功'); sys.exit(2)
except urllib.error.HTTPError as e:
    raw = e.read().decode()
try: msg = json.loads(raw).get('message', raw)
except Exception: msg = raw
m = re.search(r'#REH4#(\{.*\})', msg, re.S)
if not m: print('失敗:'); print(msg[:1800]); sys.exit(1)
res = json.loads(m.group(1)); json.dump(res, open(os.path.join(HERE, '..', '..', 'local-private', 'rehearsal4_%s.json' % time.strftime('%Y%m%d-%H%M%S'), ) if False else os.path.join(HERE, '..', '..', 'local-private', 'rehearsal4_%s.json' % time.strftime('%Y%m%d-%H%M%S')), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print('段階4リハーサル完了（巻き戻し済み）')
for k in ('day1', 'day2', 'day2_open_mismatches', 'diff_items', 'csv_rows_unchanged', 'bank_tx_before', 'bank_tx_after', 'manual_adjustment_open', 'ambiguous_open'):
    v = res[k]
    if isinstance(v, dict): v = {a: b for a, b in v.items() if a not in ('plan', 'migrate', 'notes', 'run_id')}
    print(k, json.dumps(v, ensure_ascii=False)[:700])
print('report', json.dumps({k: res['report'][k] for k in ('days_observed', 'consecutive_ok_days', 'criterion_met', 'auto_resolved_total')}, ensure_ascii=False))
