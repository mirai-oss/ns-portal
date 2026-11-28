#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""段階3の旧データの移行（本番）／同じ内容のリハーサル（巻き戻し）。1 つの DO 文＝1 つのトランザクション。途中で異常があれば、例外で全部巻き戻る（部分移行は残らない）。
  python3 tools/bank-ledger-test/migrate_stage3.py <payload.json> --rehearse   … 段階3のSQLも中で流し、最後に必ず巻き戻す（適用前の実環境の事前検証）
  python3 tools/bank-ledger-test/migrate_stage3.py <payload.json> --apply       … 段階3のSQL適用済みの本番に、移行する（異常があれば何も残らない）
やること: 旧シートの全行・備考を保存 → 取引単位で対応づけ → 旧のみ・調整を移行 → 備考 → 異常（未解決・旧のみ・銀行のみ・件数の食い違い）があれば停止
  → 本厚木などの「旧と対応済みなのに保留」を、1 対 1 を再確認して解除（承認の記録つき）→ 件数・金額・備考・既存明細の不変を検証 → 再実行で増えないことを確認。
手動調整の「正当性の承認」はしない（open のまま）。曖昧な対応（確認対象）も未確定のまま保持する。
"""
import json, os, re, sys, time, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_DIR = os.path.join(HERE, '..', '..', 'supabase')
S3 = open(os.path.join(SQL_DIR, '2026-11-28_bank_ledger_stage3.sql'), encoding='utf-8').read()
payload = json.load(open(sys.argv[1], encoding='utf-8'))
mode = 'apply' if '--apply' in sys.argv else 'rehearse'
for tag in ('$__s3__$', '$__m__$', '$__r__$', '$__n__$'):
    assert tag not in S3 and tag not in json.dumps(payload, ensure_ascii=False)
src = open(os.path.join(HERE, 'rehearsal_stage3.py'), encoding='utf-8').read()
def arr(name): return re.search(name + r' = ("array\[.*?\]")', src).group(1).strip('"')
MY_T, MY_F, MY_P, MY_TG = arr('MY_T'), arr('MY_F'), arr('MY_P'), arr('MY_TG')

body = r"""
do $__r__$
declare
  s3 text := $__s3__$__S3__$__s3__$;
  p_rows jsonb := $__m__$__ROWS__$__m__$;
  p_notes jsonb := $__n__$__NOTES__$__n__$;
  p_meta jsonb := '__META__'::jsonb;
  mode text := '__MODE__';
  res jsonb := '{}'::jsonb; t0 timestamptz := clock_timestamp();
  snap0 text; snap1 text; fp0 jsonb; fp1 jsonb; fp_ex0 text; fp_ex1 text; b uuid; pl jsonb; mg jsonb; nm jsonb; pl2 jsonb; mg2 jsonb; nm2 jsonb; rep jsonb; rep2 jsonb; v jsonb;
  hq uuid; ph_ids uuid[]; ph_n int; ph_total numeric; ok_pairs int; exp_paired int; rel_ids uuid[]; n int;
begin
  create function pg_temp.snap() returns text language sql as $f$
    select md5(coalesce(string_agg(x, '|' order by x), '')) from (
      select 'c:' || n.nspname || '.' || c.relname || ':' || c.relkind::text || ':' || c.relrowsecurity || ':' || coalesce(c.relacl::text, '') as x
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname in ('public', 'storage', 'auth') and c.relname <> all (__MY_T__) and c.relkind in ('r', 'v', 'm', 'S', 'f', 'p')
      union all select 'col:' || table_schema || '.' || table_name || '.' || column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default, '')
        from information_schema.columns where table_schema in ('public', 'storage') and table_name <> all (__MY_T__)
      union all select 'pol:' || schemaname || '.' || tablename || '.' || policyname || ':' || cmd || ':' || coalesce(roles::text, '') || ':' || coalesce(qual, '') || ':' || coalesce(with_check, '')
        from pg_policies where policyname <> all (__MY_P__)
      union all select 'fn:' || n.nspname || '.' || p.proname || ':' || md5(p.prosrc) || ':' || coalesce(p.proacl::text, '')
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public', 'storage') and p.proname <> all (__MY_F__)
      union all select 'trg:' || tgrelid::regclass::text || '.' || tgname || ':' || md5(pg_get_triggerdef(oid))
        from pg_trigger where not tgisinternal and tgname <> all (__MY_TG__)
      union all select 'bkt:' || id || ':' || public || ':' || coalesce(file_size_limit::text, '') || ':' || coalesce(allowed_mime_types::text, '')
        from storage.buckets where id <> 'bank-csv-originals'
    ) q
  $f$;
  create function pg_temp.as_user(p_uid uuid, p_role text, p_sql text) returns jsonb language plpgsql as $f$
  declare r jsonb;
  begin
    execute format('set local role %I', p_role);
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true);
    begin
      execute 'select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from (' || p_sql || ') x' into r;
      r := jsonb_build_object('ok', true, 'rows', r);
    exception when others then r := jsonb_build_object('ok', false, 'err', sqlerrm); end;
    reset role; perform set_config('request.jwt.claims', '', true);
    return r;
  end $f$;
  -- 既存の銀行CSV由来の明細の指紋（本厚木の解除対象を除いた版も）
  create function pg_temp.fp_excl(p_ids uuid[]) returns text language sql as $f$
    select md5(coalesce(string_agg(concat_ws('|', t.id, t.bank_account_id, t.store_id, t.corporation_id, t.txn_date, t.txn_time, t.description, t.deposit_amount, t.withdrawal_amount, t.balance,
           t.dedupe_key, t.match_status, t.hold_reason, t.tx_kind, t.counts_as_sales_deposit, t.import_file_id, t.confirm_status, t.adj_deposit_amount, t.adj_description, t.adj_txn_date), ',' order by t.id), ''))
      from public.bank_transactions t where t.source_kind in ('playwright', 'manual_csv') and not (t.id = any (coalesce(p_ids, '{}')))
  $f$;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  snap0 := pg_temp.snap();
  if mode = 'rehearse' then execute s3; perform set_config('request.jwt.claims', '{"role":"service_role"}', true); end if;
  if to_regprocedure('public.bank_legacy_load(jsonb,jsonb,jsonb)') is null then raise exception '段階3のSQLが適用されていません'; end if;
  snap1 := pg_temp.snap();
  if snap0 <> snap1 then raise exception '段階3のSQLの前後で、既存の物（表・関数・ポリシー・トリガー等）の指紋が変わりました。停止します'; end if;
  fp0 := public.bank_csv_rows_fingerprint();
  res := res || jsonb_build_object('mode', mode, 'existing_objects_unchanged', true, 'csv_rows_before', fp0);
  if (select count(*) from public.bank_legacy_batches) > 0 and mode = 'apply' then raise exception 'すでに旧データの移行が行われています（バッチ有り）。停止します'; end if;

  -- 1. 旧シートの全行・備考を保存
  b := public.bank_legacy_load(p_meta, p_rows, p_notes);
  if (select count(*) from public.bank_legacy_rows where batch_id = b) <> jsonb_array_length(p_rows) then raise exception '保存した行数が取り出した行数と一致しません'; end if;
  if (select count(*) from public.bank_legacy_notes where batch_id = b) <> jsonb_array_length(p_notes) then raise exception '保存した備考の数が一致しません'; end if;

  -- 2. 取引単位の対応づけ → 異常があれば停止（未検証の差分を持ち込まない）
  select count(*) into exp_paired from public.bank_transactions t
   where t.source_kind in ('playwright', 'manual_csv') and t.counts_as_sales_deposit and t.deposit_amount > 0 and t.store_id is not null and t.match_status in ('verified', 'held');
  pl := public.bank_legacy_plan(b);
  if (pl ->> 'unresolved')::int <> 0 then raise exception '店舗が決まらない旧行があります（%）。停止します', pl; end if;
  if (pl ->> 'legacy_only_in_window')::int <> 0 then raise exception '銀行CSVの期間内に、銀行に無い旧のみの行があります（%）。停止します', pl; end if;
  if (pl ->> 'bank_only')::int <> 0 then raise exception '旧シートに無い銀行の入金があります（%）。停止します', pl; end if;
  if (pl ->> 'paired')::int <> exp_paired then raise exception '対応づけ数（%）が銀行CSV由来の売上入金数（%）と一致しません。停止します', pl ->> 'paired', exp_paired; end if;
  if (pl ->> 'adjustments')::int <> 79 then raise exception '手動調整の件数が 79 ではありません（%）。停止します', pl ->> 'adjustments'; end if;
  if (pl ->> 'paired_held')::int <> 5 then raise exception '旧と対応済みの保留が 5 件ではありません（%）。停止します', pl ->> 'paired_held'; end if;

  -- 3. 移行（旧のみ・手動調整＝数字を維持）と備考
  mg := public.bank_legacy_migrate(b);
  nm := public.bank_legacy_migrate_notes(b);
  if (mg ->> 'still_unmigrated')::int <> 0 then raise exception '未移行の行が残っています（%）', mg; end if;
  if (nm ->> 'mismatch')::int <> 0 or (nm ->> 'unresolved')::int <> 0 then raise exception '備考に不一致・未解決があります（%）', nm; end if;
  fp1 := public.bank_csv_rows_fingerprint();
  if fp0 <> fp1 then raise exception '移行で、既存の銀行CSV由来の明細が変わりました。停止します'; end if;

  -- 4. 保留の解除（旧と対応済みの保留）: 同一店舗ID・日付・金額の 1 対 1 を再確認 → 解除（承認の記録つき）
  select array_agg(id order by id), count(*), coalesce(sum(amount), 0) into ph_ids, ph_n, ph_total from public.bank_diff_items where kind = 'paired_held' and batch_id = b;
  select array_agg(d.transaction_ids[1]) into rel_ids from public.bank_diff_items d where d.kind = 'paired_held' and d.batch_id = b;
  select count(*) into ok_pairs from public.bank_diff_items d join public.bank_transactions t on t.id = d.transaction_ids[1]
     join public.bank_legacy_links k on k.transaction_id = t.id and k.kind = 'paired' and k.confidence in ('auto', 'approved')
     join public.bank_legacy_rows r on r.content_hash || '#' || r.ordinal = k.legacy_key and r.store_id = t.store_id and r.txn_date = t.txn_date and r.amount = t.deposit_amount
    where d.kind = 'paired_held' and d.batch_id = b
      and (select count(*) from public.bank_legacy_links k2 where k2.transaction_id = t.id) = 1 and (select count(*) from public.bank_legacy_links k3 where k3.legacy_key = k.legacy_key) = 1;
  if ph_n <> 5 or ok_pairs <> 5 then raise exception '保留の解除対象 5 件の 1 対 1 が確かめられません（対象 %・確認済み %）。停止します', ph_n, ok_pairs; end if;
  fp_ex0 := pg_temp.fp_excl(rel_ids);
  select id into hq from public.users where role = 'HQ' and is_active order by (name = '連携用') desc nulls last, created_at limit 1;
  v := pg_temp.as_user(hq, 'authenticated', format('select public.bank_diff_decide(%L::uuid[], ''approved'', %L, ''paired_held'', %s, %s) r', ph_ids,
        '社長の承認（2026-11-28・チャットでの指示）に基づく解除。旧シートの行と、同一店舗ID・日付・金額の1対1の対応を再確認済み（実行: Claude・連携用アカウント）', ph_n, ph_total));
  if not (v ->> 'ok')::boolean then raise exception '保留の解除に失敗: %', v ->> 'err'; end if;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  if (select count(*) from public.bank_transactions where id = any (rel_ids) and match_status = 'verified') <> 5 then raise exception '解除後、5 件が照合済みになっていません'; end if;
  fp_ex1 := pg_temp.fp_excl(rel_ids);
  if fp_ex0 <> fp_ex1 then raise exception '解除の対象以外の銀行CSV由来の明細が変わりました。停止します'; end if;

  -- 5. 検証: 件数・金額（店舗×日付）・備考・保存則
  rep := public.bank_legacy_report(b);
  if (rep ->> 'legacy_rows')::int <> jsonb_array_length(p_rows) or (rep ->> 'legacy_rows_saved')::int <> jsonb_array_length(p_rows) then raise exception '旧行の保存数が一致しません'; end if;
  if (rep ->> 'rows_without_link')::int <> 0 or (rep ->> 'rows_unmigrated')::int <> 0 then raise exception '対応づけのない行・未移行の行があります（%）', rep; end if;
  if (rep ->> 'store_dates_mismatch')::int <> 0 or (rep ->> 'legacy_total')::numeric <> (rep ->> 'ledger_total')::numeric then raise exception '店舗×日付の件数・金額が旧シートと一致しません（食い違い % 組）', rep ->> 'store_dates_mismatch'; end if;
  if (rep ->> 'notes_saved')::int <> jsonb_array_length(p_notes) or (rep ->> 'notes_in_ledger_same')::int <> jsonb_array_length(p_notes) then raise exception '備考が旧シートと一致しません（%）', rep; end if;
  if (rep -> 'adjustments' ->> 'rows')::int <> 79 or (rep -> 'adjustments' ->> 'numbers_preserved_rows')::int <> 79 or (rep -> 'adjustments' ->> 'legitimacy_approved')::int <> 0
     or (rep -> 'adjustments' ->> 'individual_distinct')::int <> 9 or (rep -> 'adjustments' ->> 'bulk_pending')::int <> 70 then raise exception '手動調整の移行状態が想定と違います（%）', rep -> 'adjustments'; end if;
  if (select count(*) from public.bank_diff_items where kind = 'ambiguous_pair' and status = 'open') <> (pl ->> 'ambiguous_pairs')::int then raise exception '曖昧な対応が未確定のまま保持されていません'; end if;
  if exists (select 1 from public.bank_transactions where tx_kind = 'adjustment' and (bank_account_id is not null)) then raise exception '調整の行が銀行口座に結び付いています'; end if;

  -- 6. 再実行しても増えない
  pl2 := public.bank_legacy_plan(b); mg2 := public.bank_legacy_migrate(b); nm2 := public.bank_legacy_migrate_notes(b);
  if exists (select 1 from jsonb_each_text(pl2) e where e.value::int <> 0) or (mg2 ->> 'migrated_rows')::int <> 0 or (nm2 ->> 'inserted')::int <> 0 then raise exception '再実行で増えました（% % %）', pl2, mg2, nm2; end if;
  if pg_temp.snap() <> snap0 then raise exception '移行のあと、既存の物の指紋が変わりました。停止します'; end if;

  res := res || jsonb_build_object('batch', b, 'plan', pl, 'migrate', mg, 'notes', nm, 'report', rep, 'release', v, 'plan_again', pl2, 'migrate_again', mg2, 'notes_again', nm2,
     'csv_rows_after_release', public.bank_csv_rows_fingerprint(), 'elapsed_sec', round(extract(epoch from clock_timestamp() - t0)::numeric, 2));
  if mode = 'rehearse' then raise exception '#MIG#%', res::text; end if;
end
$__r__$;
"""
body = (body.replace('__S3__', S3).replace('__ROWS__', json.dumps(payload['rows'], ensure_ascii=False)).replace('__NOTES__', json.dumps(payload['notes'], ensure_ascii=False))
        .replace('__META__', json.dumps(payload['meta'], ensure_ascii=False).replace("'", "''")).replace('__MODE__', mode)
        .replace('__MY_T__', MY_T).replace('__MY_F__', MY_F).replace('__MY_P__', MY_P).replace('__MY_TG__', MY_TG))
if '--print' in sys.argv: print(len(body), 'bytes'); sys.exit(0)
pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
req = urllib.request.Request('https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query', data=json.dumps({'query': body}).encode(),
                             headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json', 'User-Agent': 'curl/8'})
t = time.time()
try:
    out = urllib.request.urlopen(req, timeout=900).read().decode()
    if mode == 'rehearse': print('想定外: リハーサルが例外で終わらず成功（巻き戻っていない可能性）', out[:200]); sys.exit(2)
    print('移行 完了（コミット済み）: %.1f 秒' % (time.time() - t)); sys.exit(0)
except urllib.error.HTTPError as e:
    raw = e.read().decode()
try: msg = json.loads(raw).get('message', raw)
except Exception: msg = raw
m = re.search(r'#MIG#(\{.*\})', msg, re.S)
if mode == 'rehearse' and m:
    res = json.loads(m.group(1)); os.makedirs(os.path.join(HERE, '..', '..', 'local-private'), exist_ok=True)
    stamp = time.strftime('%Y%m%d-%H%M%S'); json.dump(res, open(os.path.join(HERE, '..', '..', 'local-private', f'migrate_rehearsal_{stamp}.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
    print('事前検証（リハーサル）成功: 全ての検査を通過し、巻き戻し済み（%.1f 秒）' % (time.time() - t)); print(json.dumps({k: res[k] for k in ('mode', 'existing_objects_unchanged', 'plan', 'migrate', 'notes', 'plan_again', 'migrate_again', 'notes_again', 'elapsed_sec')}, ensure_ascii=False)); sys.exit(0)
print('停止（全て巻き戻し済み）:'); print(msg[:1500]); sys.exit(1)
