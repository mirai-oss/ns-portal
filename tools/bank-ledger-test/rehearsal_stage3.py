#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""段階3（旧シートの移行）の【リハーサル】: 実データで、段階3のSQL適用→旧シートの保存→対応づけ→移行→備考→検証→承認の流れを、
1 つのトランザクションで最後まで流して、必ず巻き戻す。本番には何も残らない（最後に必ず例外で終わる）。
  python3 tools/bank-ledger-test/rehearsal_stage3.py <取り出し結果の payload.json> [--print]
payload.json は ns-daily-import の `node bank-ledger-cli.js legacy-payload` が作る（{meta, rows, notes}。店舗IDは別名つきで解決済み）。
結果（件数・検証・差異の一覧）は local-private/ に HTML と JSON で保存（金額が入るので Git には入らない）。
"""
import json, os, re, sys, time, urllib.request, urllib.error, html

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_DIR = os.path.join(HERE, '..', '..', 'supabase')
OUT = os.path.join(HERE, '..', '..', 'local-private')
S3 = open(os.path.join(SQL_DIR, '2026-11-28_bank_ledger_stage3.sql'), encoding='utf-8').read()
payload = json.load(open(sys.argv[1], encoding='utf-8'))
for tag in ('$__s3__$', '$__m__$', '$__r__$', '$__n__$'):
    assert tag not in S3 and tag not in json.dumps(payload, ensure_ascii=False)

MY_T = "array['bank_accounts','bank_csv_originals','bank_import_files','bank_transactions','bank_transaction_events','bank_account_sync_state','bank_deposit_notes','bank_legacy_batches','bank_legacy_rows','bank_legacy_notes','bank_legacy_links','bank_diff_items','bank_decision_batches','bank_diff_decisions']"
MY_F = "array['bank_ledger_admin','bank_store_visible','bank_tx_guard','bank_append_only','bank_import_files_guard','bank_tx_correct','bank_deposit_daily','bank_sync_status','bank_assert_service','bank_account_upsert','bank_import_register','bank_import_attach_original','bank_import_record_verification','bank_import_ingest','bank_import_commit','bank_import_fail','bank_legacy_guard','bank_legacy_load','bank_legacy_plan','bank_legacy_changes','bank_legacy_migrate','bank_legacy_migrate_notes','bank_diff_decide','bank_csv_rows_fingerprint','bank_legacy_report']"
MY_P = "array['bank_accounts_read','bank_csv_originals_tbl_read','bank_import_files_read','bank_transactions_read','bank_tx_events_read','bank_sync_state_read','bank_deposit_notes_read','bank_deposit_notes_write','bank_csv_originals_read','bank_csv_originals_insert','bank_legacy_batches_read','bank_legacy_rows_read','bank_legacy_notes_read','bank_legacy_links_read','bank_diff_items_read','bank_decision_batches_read','bank_diff_decisions_read']"
MY_TG = "array['bank_tx_guard_trg','bank_tx_events_append_only','bank_csv_originals_append_only','bank_import_files_guard_trg','bank_legacy_batches_append_only','bank_legacy_rows_append_only','bank_legacy_notes_append_only','bank_decision_batches_append_only','bank_diff_decisions_append_only','bank_legacy_links_guard_trg','bank_diff_items_guard_trg']"

body = r"""
do $__r__$
declare
  s3 text := $__s3__$__S3__$__s3__$;
  p_rows jsonb := $__m__$__ROWS__$__m__$;
  p_notes jsonb := $__n__$__NOTES__$__n__$;
  p_meta jsonb := '__META__'::jsonb;
  res jsonb := '{}'::jsonb; t0 timestamptz := clock_timestamp();
  snap0 text; snap1 text; fp0 jsonb; fp1 jsonb; b uuid; b2 uuid; pl jsonb; pl2 jsonb; mg jsonb; mg2 jsonb; nm jsonb; nm2 jsonb; rep jsonb; v jsonb;
  ceo uuid; hq uuid; ids uuid[]; ids1 uuid[]; adj_ids uuid[]; n int;
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
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  snap0 := pg_temp.snap();
  select count(*) into n from public.bank_transactions where source_kind in ('playwright', 'manual_csv');
  res := res || jsonb_build_object('existing_csv_rows_before', n);

  -- 1. 段階3のSQLを流す（既存の物の指紋が変わらないこと）
  execute s3;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  snap1 := pg_temp.snap();
  fp0 := public.bank_csv_rows_fingerprint();
  res := res || jsonb_build_object('stage3_applied', true, 'existing_objects_unchanged_by_stage3', snap0 = snap1, 'csv_fingerprint_before', fp0);

  -- 2. 旧シートの全行・全備考を控えに保存 → 同じ内容をもう一度保存しても増えない
  b := public.bank_legacy_load(p_meta, p_rows, p_notes);
  b2 := public.bank_legacy_load(p_meta, p_rows, p_notes);
  res := res || jsonb_build_object('batch_reused_on_second_load', b = b2, 'batches', (select count(*) from public.bank_legacy_batches));

  -- 3. 対応づけ → 移行 → 備考。2 回目は何も増やさない
  pl := public.bank_legacy_plan(b); mg := public.bank_legacy_migrate(b); nm := public.bank_legacy_migrate_notes(b);
  pl2 := public.bank_legacy_plan(b); mg2 := public.bank_legacy_migrate(b); nm2 := public.bank_legacy_migrate_notes(b);
  res := res || jsonb_build_object('plan', pl, 'migrate', mg, 'notes', nm, 'plan_again', pl2, 'migrate_again', mg2, 'notes_again', nm2);

  -- 4. 検証レポート
  rep := public.bank_legacy_report(b);
  fp1 := public.bank_csv_rows_fingerprint();
  res := res || jsonb_build_object('report', rep, 'csv_fingerprint_after', fp1, 'existing_csv_rows_unchanged', fp0 = fp1);

  -- 5. 差異の一覧
  res := res || jsonb_build_object(
    'diff_counts', (select jsonb_object_agg(kind || '/' || status, c) from (select kind, status, count(*) c from public.bank_diff_items group by 1, 2) q),
    'adjustments', (select jsonb_agg(jsonb_build_object('id', d.id, 'store', s.name, 'date', d.txn_date, 'desc', d.description, 'amount', d.amount, 'status', d.status) order by s.name, d.txn_date, d.id)
                      from public.bank_diff_items d left join public.stores s on s.id = d.store_id where d.kind = 'manual_adjustment'),
    'others', (select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'store', s.name, 'date', d.txn_date, 'desc', d.description, 'amount', d.amount, 'status', d.status, 'detail', d.detail) order by d.kind, s.name, d.txn_date)
                 from public.bank_diff_items d left join public.stores s on s.id = d.store_id where d.kind <> 'manual_adjustment'),
    'same_day_groups', (select jsonb_agg(jsonb_build_object('store', s.name, 'date', g.txn_date, 'amount', g.amount, 'legacy_rows', g.n, 'paired', g.paired, 'proposed', g.proposed, 'migrated', g.migrated, 'adjustment', g.adj) order by s.name, g.txn_date)
                          from (select r.store_id, r.txn_date, r.amount, count(*) n,
                                       count(*) filter (where k.kind = 'paired') paired, count(*) filter (where k.kind = 'paired' and k.confidence = 'proposed') proposed,
                                       count(*) filter (where k.kind = 'migrated') migrated, count(*) filter (where k.kind = 'adjustment') adj
                                  from public.bank_legacy_rows r join public.bank_legacy_links k on k.legacy_key = r.content_hash || '#' || r.ordinal
                                 where r.batch_id = b group by 1, 2, 3 having count(*) > 1) g left join public.stores s on s.id = g.store_id),
    'basis_counts', (select jsonb_object_agg(coalesce(basis, '-') || '/' || confidence, c) from (select basis, confidence, count(*) c from public.bank_legacy_links where kind = 'paired' group by 1, 2) q),
    'migrated_basis', (select jsonb_object_agg(coalesce(basis, '-'), c) from (select basis, count(*) c from public.bank_legacy_links where kind = 'migrated' group by 1) q));

  -- 6. 実在の社長・本部で、一括承認・個別承認が動くこと（巻き戻す）
  select id into ceo from public.users where role = 'CEO' and is_active limit 1;
  select id into hq from public.users where role = 'HQ' and is_active limit 1;
  select array_agg(id order by id) into adj_ids from public.bank_diff_items where kind = 'manual_adjustment';
  if adj_ids is not null and ceo is not null then
    v := pg_temp.as_user(hq, 'authenticated', format('select public.bank_diff_decide(%L::uuid[], ''approved'', ''リハーサル: 手動調整を一括承認'', ''manual_adjustment'') r', adj_ids));
    res := res || jsonb_build_object('bulk_approve', v);
    v := pg_temp.as_user(ceo, 'authenticated', format('select public.bank_diff_decide(%L::uuid[], ''held'', ''リハーサル: 個別に保留へ戻す'', ''manual_adjustment'') r', array[adj_ids[1]]));
    res := res || jsonb_build_object('single_hold', v,
      'decision_batches', (select jsonb_agg(jsonb_build_object('mode', mode, 'decision', decision, 'items', item_count, 'listed', array_length(item_ids, 1), 'actor', actor_label, 'has_time', decided_at is not null, 'reason', reason)) from public.bank_decision_batches),
      'decisions_rows', (select count(*) from public.bank_diff_decisions));
    v := pg_temp.as_user(null, 'anon', format('select public.bank_diff_decide(%L::uuid[], ''approved'', ''x'') r', adj_ids));
    res := res || jsonb_build_object('anon_decide_denied', not (v ->> 'ok')::boolean);
    -- 旧と対応済みなのに保留のままの行（店舗名の別表記で「旧に無い」と見えていたもの）を承認して保留を解く → 旧との数字のずれが消える
    select array_agg(id order by id) into ids from public.bank_diff_items where kind = 'paired_held';
    if ids is not null then
      v := pg_temp.as_user(ceo, 'authenticated', format('select public.bank_diff_decide(%L::uuid[], ''approved'', ''リハーサル: 旧シートに同じ入金が有るので保留を解く'', ''paired_held'') r', ids));
      perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
      res := res || jsonb_build_object('release_paired_held', v, 'report_after_release', public.bank_legacy_report(b));
    end if;
  end if;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  res := res || jsonb_build_object('csv_fingerprint_after_decisions', public.bank_csv_rows_fingerprint(),
    'csv_rows_changed_by_release', (select count(*) from public.bank_transactions where source_kind in ('playwright', 'manual_csv') and match_status = 'verified' and exists (select 1 from public.bank_transaction_events e where e.transaction_id = bank_transactions.id and e.event_kind = 'release')), 'elapsed_sec', round(extract(epoch from clock_timestamp() - t0)::numeric, 2));
  raise exception '#REH#%', res::text;
end
$__r__$;
"""
body = (body.replace('__S3__', S3).replace('__ROWS__', json.dumps(payload['rows'], ensure_ascii=False))
        .replace('__NOTES__', json.dumps(payload['notes'], ensure_ascii=False)).replace('__META__', json.dumps(payload['meta'], ensure_ascii=False).replace("'", "''"))
        .replace('__MY_T__', MY_T).replace('__MY_F__', MY_F).replace('__MY_P__', MY_P).replace('__MY_TG__', MY_TG))
if '--print' in sys.argv:
    print(body[:2000]); print(len(body), 'bytes'); sys.exit(0)

pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
req = urllib.request.Request('https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query', data=json.dumps({'query': body}).encode(),
                             headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json', 'User-Agent': 'curl/8'})
t = time.time()
try:
    out = urllib.request.urlopen(req, timeout=600).read().decode(); print('想定外: 例外で終わらず成功', out[:300]); sys.exit(2)
except urllib.error.HTTPError as e:
    raw = e.read().decode()
try: msg = json.loads(raw).get('message', raw)
except Exception: msg = raw
m = re.search(r'#REH#(\{.*\})', msg, re.S)
if not m:
    print('リハーサルが結果まで届きませんでした:'); print(msg[:2500]); sys.exit(1)
res = json.loads(m.group(1))
os.makedirs(OUT, exist_ok=True)
stamp = time.strftime('%Y%m%d-%H%M%S')
json.dump(res, open(os.path.join(OUT, f'rehearsal_{stamp}.json'), 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
def esc(x): return html.escape(str(x if x is not None else ''))
def table(rows, cols):
    h = '<table><tr>' + ''.join('<th>%s</th>' % esc(c[0]) for c in cols) + '</tr>'
    for r in rows: h += '<tr>' + ''.join('<td class="%s">%s</td>' % (c[2] if len(c) > 2 else '', esc(c[1](r))) for c in cols) + '</tr>'
    return h + '</table>'
yen = lambda a: '{:,}'.format(int(a)) if a is not None else ''
page = '<!doctype html><html lang="ja"><meta charset="utf-8"><title>旧シート移行リハーサル 確認一覧</title><style>body{font:15px/1.6 -apple-system,"Hiragino Sans",sans-serif;margin:20px;max-width:1100px}table{border-collapse:collapse;margin:8px 0 24px}th,td{border:1px solid #ccc;padding:4px 8px}th{background:#f2f4f7}td.n{text-align:right}h2{margin-top:32px}.note{color:#555}</style>'
page += '<h1>旧シート移行リハーサル 確認一覧（%s）</h1><p class="note">本番には何も書いていません（巻き戻し済み）。金額を含むので、このファイルはGitに入れません。</p>' % stamp
page += '<h2>1. 手動調整（%d行）— 店舗・日付・摘要・金額</h2>' % len(res.get('adjustments') or [])
page += table(res.get('adjustments') or [], [('店舗', lambda r: r['store']), ('日付', lambda r: r['date']), ('摘要', lambda r: r['desc']), ('金額', lambda r: yen(r['amount']), 'n'), ('状態（リハーサル中の操作後）', lambda r: r['status'])])
others = res.get('others') or []
for kind, title in (('paired_held', '2. 旧と対応済みなのに保留のままの銀行の入金'), ('ambiguous_pair', '3. 時刻で特定できない同日同額の対応（確認対象。件数・金額は変わらない）'), ('legacy_only_in_window', '4. 銀行CSVの期間内で、銀行に無い旧のみの行'), ('bank_only', '5. 旧に無い銀行の入金'), ('unresolved_store', '6. 店舗が決まらない行')):
    rows = [o for o in others if o['kind'] == kind]
    page += '<h2>%s（%d件）</h2>' % (title, len(rows))
    if rows: page += table(rows, [('店舗', lambda r: r['store']), ('日付', lambda r: r['date']), ('摘要', lambda r: r['desc']), ('金額', lambda r: yen(r['amount']), 'n'), ('状態', lambda r: r['status']), ('詳細', lambda r: json.dumps(r['detail'], ensure_ascii=False)[:90])])
g = res.get('same_day_groups') or []
page += '<h2>7. 同日同額の旧行のグループ（%d組）— 統合せず、対応づけの結果</h2>' % len(g)
page += table(g, [('店舗', lambda r: r['store']), ('日付', lambda r: r['date']), ('金額', lambda r: yen(r['amount']), 'n'), ('旧の行数', lambda r: r['legacy_rows'], 'n'), ('銀行と対応', lambda r: r['paired'], 'n'), ('うち確認対象', lambda r: r['proposed'], 'n'), ('旧のみ（移行）', lambda r: r['migrated'], 'n'), ('調整', lambda r: r['adjustment'], 'n')])
open(os.path.join(OUT, f'rehearsal_review_{stamp}.html'), 'w', encoding='utf-8').write(page + '</html>')
print('確認一覧 → local-private/rehearsal_review_%s.html' % stamp)
print('リハーサル完了（全て巻き戻し済み・%.1f 秒）→ local-private/rehearsal_%s.json' % (time.time() - t, stamp))
print(json.dumps({k: v for k, v in res.items() if k not in ('adjustments', 'others', 'same_day_groups')}, ensure_ascii=False, indent=1)[:6000])
