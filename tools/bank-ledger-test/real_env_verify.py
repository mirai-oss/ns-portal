#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""実際の Supabase（ハブ）で、段階1の SQL を「流して・確かめて・必ず巻き戻す」事前検証。
  python3 tools/bank-ledger-test/real_env_verify.py            # 検証を実行（何も残らない）
  python3 tools/bank-ledger-test/real_env_verify.py --print    # 送る SQL を表示だけ（送らない）

仕組み: 全体を 1 つの DO 文（＝1 つのトランザクション）にして、最後に必ず例外を投げる。
  → 途中で何が起きても、最後に例外で終わっても、データベースには何も残らない（begin/rollback の取りこぼしが無い）。
  結果は、最後の例外メッセージに JSON で入れて受け取る。
使うもの: ~/.config/ns-portal/supabase_pat（画面・ログに出さない）。
やること（ざっくり）:
  1. 既存の物（既存テーブル・ポリシー・関数・バケット）の指紋をとる
  2. 段階1の SQL を流す → 指紋が変わらないこと／2 回流しても同じこと
  3. 空の状態でロールバック SQL を流す → 指紋が元に戻ること → もう一度段階1を流す
  4. 使い捨てのデータ（本物の店舗を参照するだけ。実ユーザー・実店舗・実チームは変更しない）を入れる
  5. 本物のユーザー全員（ログインを模して）について、見える店舗が期待どおりか／権限（anon・authenticated・service_role）／Storage／守り／保存確認
  6. データが入った状態でロールバック SQL が止まること
  7. 例外で巻き戻す
"""
import json, os, re, sys, urllib.request, urllib.error, time

HERE = os.path.dirname(os.path.abspath(__file__))
SQL_DIR = os.path.join(HERE, '..', '..', 'supabase')
STAGE1 = open(os.path.join(SQL_DIR, '2026-11-27_bank_ledger_stage1.sql'), encoding='utf-8').read()
ROLLBACK = open(os.path.join(SQL_DIR, '2026-11-27_bank_ledger_stage1_ROLLBACK.sql'), encoding='utf-8').read()
for tag, body in (('$__s1__$', STAGE1), ('$__rb__$', ROLLBACK)):
    assert tag not in body

body = r"""
do $__verify__$
declare
  res jsonb := '[]'::jsonb;
  t0 timestamptz := clock_timestamp();
  snap0 text; snap1 text; snap2 text; snap3 text; hb1 text; hb2 text;
  stage1 text := $__s1__$__STAGE1__$__s1__$;
  rbsql  text := $__rb__$__ROLLBACK__$__rb__$;
  v jsonb; v2 jsonb; n int; r record; u record; s record;
  v_ids uuid[]; v_exp uuid[]; v_act uuid[]; v_bad int := 0; v_checked int := 0;
  v_admins uuid[]; v_team uuid; v_tencho uuid; v_ceo uuid; v_al uuid; v_inactive uuid; v_master uuid; v_hq uuid;
  v_err text;
  v_shain uuid; v_acct uuid; v_orig uuid; v_if uuid; v_tx uuid; v_store uuid; v_other uuid; v_teamid uuid;
  v_sha text := repeat('a', 64);
begin
  -- ===== 補助（この DO の中だけ）=====
  create function pg_temp.snap() returns text language sql as $f$
    select md5(coalesce(string_agg(x, '|' order by x), '')) from (
      select 'c:' || n.nspname || '.' || c.relname || ':' || c.relkind::text || ':' || c.relrowsecurity || ':' || coalesce(c.relacl::text, '') as x
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname in ('public', 'storage', 'auth') and c.relname <> all (array['bank_accounts','bank_csv_originals','bank_import_files','bank_transactions','bank_transaction_events','bank_account_sync_state','bank_deposit_notes']) and c.relkind in ('r', 'v', 'm', 'S', 'f', 'p')
      union all
      select 'col:' || table_schema || '.' || table_name || '.' || column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default, '')
        from information_schema.columns where table_schema in ('public', 'storage') and table_name <> all (array['bank_accounts','bank_csv_originals','bank_import_files','bank_transactions','bank_transaction_events','bank_account_sync_state','bank_deposit_notes'])
      union all
      select 'pol:' || schemaname || '.' || tablename || '.' || policyname || ':' || cmd || ':' || coalesce(roles::text, '') || ':' || coalesce(qual, '') || ':' || coalesce(with_check, '')
        from pg_policies where policyname <> all (array['bank_accounts_read','bank_csv_originals_tbl_read','bank_import_files_read','bank_transactions_read','bank_tx_events_read','bank_sync_state_read','bank_deposit_notes_read','bank_deposit_notes_write','bank_csv_originals_read','bank_csv_originals_insert'])
      union all
      select 'fn:' || n.nspname || '.' || p.proname || ':' || md5(p.prosrc) || ':' || coalesce(p.proacl::text, '')
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname in ('public', 'storage') and p.proname <> all (array['bank_ledger_admin','bank_store_visible','bank_tx_guard','bank_append_only','bank_import_files_guard','bank_tx_correct','bank_deposit_daily','bank_sync_status'])
      union all
      select 'trg:' || tgrelid::regclass::text || '.' || tgname || ':' || md5(pg_get_triggerdef(oid))
        from pg_trigger where not tgisinternal and tgname <> all (array['bank_tx_guard_trg','bank_tx_events_append_only','bank_csv_originals_append_only','bank_import_files_guard_trg'])
      union all
      select 'bkt:' || id || ':' || public || ':' || coalesce(file_size_limit::text, '') || ':' || coalesce(allowed_mime_types::text, '')
        from storage.buckets where id <> 'bank-csv-originals'
    ) q
  $f$;
  create function pg_temp.bank_defs() returns text language sql as $f$
    select md5(coalesce(string_agg(x, '|' order by x), '')) from (
      select 'pol:' || tablename || '.' || policyname || ':' || cmd || ':' || coalesce(qual, '') || ':' || coalesce(with_check, '') as x from pg_policies where policyname = any (array['bank_accounts_read','bank_csv_originals_tbl_read','bank_import_files_read','bank_transactions_read','bank_tx_events_read','bank_sync_state_read','bank_deposit_notes_read','bank_deposit_notes_write','bank_csv_originals_read','bank_csv_originals_insert'])
      union all select 'fn:' || proname || ':' || md5(prosrc) || ':' || coalesce(proacl::text, '') from pg_proc where pronamespace = 'public'::regnamespace and proname = any (array['bank_ledger_admin','bank_store_visible','bank_tx_guard','bank_append_only','bank_import_files_guard','bank_tx_correct','bank_deposit_daily','bank_sync_status'])
      union all select 'trg:' || tgname || ':' || md5(pg_get_triggerdef(oid)) from pg_trigger where not tgisinternal and tgname = any (array['bank_tx_guard_trg','bank_tx_events_append_only','bank_csv_originals_append_only','bank_import_files_guard_trg'])
      union all select 'tbl:' || c.relname || ':' || c.relrowsecurity || ':' || coalesce(c.relacl::text, '') from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname = any (array['bank_accounts','bank_csv_originals','bank_import_files','bank_transactions','bank_transaction_events','bank_account_sync_state','bank_deposit_notes']) and c.relkind = 'r'
      union all select 'col:' || table_name || '.' || column_name || ':' || data_type from information_schema.columns where table_schema = 'public' and table_name = any (array['bank_accounts','bank_csv_originals','bank_import_files','bank_transactions','bank_transaction_events','bank_account_sync_state','bank_deposit_notes'])
      union all select 'bkt:' || id || ':' || public || ':' || coalesce(file_size_limit::text, '') from storage.buckets where id = 'bank-csv-originals'
    ) q
  $f$;
  -- ログインを模して SELECT を流す（結果を jsonb で返す。失敗しても落ちない）
  create function pg_temp.as_user(p_uid uuid, p_role text, p_sql text) returns jsonb language plpgsql as $f$
  declare r jsonb;
  begin
    execute format('set local role %I', p_role);
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true);
    begin
      execute 'select coalesce(jsonb_agg(to_jsonb(x)), ''[]''::jsonb) from (' || p_sql || ') x' into r;
      r := jsonb_build_object('ok', true, 'rows', r);
    exception when others then
      r := jsonb_build_object('ok', false, 'err', sqlerrm);
    end;
    reset role;
    perform set_config('request.jwt.claims', '', true);
    return r;
  end $f$;
  -- ログインを模して INSERT/UPDATE/DELETE を流す（影響した行数を返す）
  create function pg_temp.dml_as(p_uid uuid, p_role text, p_sql text) returns jsonb language plpgsql as $f$
  declare r jsonb; c bigint;
  begin
    execute format('set local role %I', p_role);
    perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', p_role)::text, true);
    begin
      execute p_sql;
      get diagnostics c = row_count;
      r := jsonb_build_object('ok', true, 'n', c);
    exception when others then
      r := jsonb_build_object('ok', false, 'err', sqlerrm);
    end;
    reset role;
    perform set_config('request.jwt.claims', '', true);
    return r;
  end $f$;

  -- ===== 1〜2. 既存の指紋 → 段階1 → 指紋が変わらない／2 回目も同じ =====
  snap0 := pg_temp.snap();
  execute stage1;
  snap1 := pg_temp.snap();
  hb1 := pg_temp.bank_defs();
  res := res || jsonb_build_array(jsonb_build_object('n', '段階1を流せた（エラー無し）', 'ok', true));
  res := res || jsonb_build_array(jsonb_build_object('n', '既存の表・列・ポリシー・関数・トリガー・他バケットの指紋が、段階1の前後で同じ', 'ok', snap0 = snap1));
  select count(*) into n from pg_class where relnamespace = 'public'::regnamespace and relname = any (array['bank_accounts','bank_csv_originals','bank_import_files','bank_transactions','bank_transaction_events','bank_account_sync_state','bank_deposit_notes']) and relkind = 'r';
  res := res || jsonb_build_array(jsonb_build_object('n', '新しい表は 7 つ', 'ok', n = 7, 'i', n));
  execute stage1;
  hb2 := pg_temp.bank_defs();
  res := res || jsonb_build_array(jsonb_build_object('n', '2 回目に流しても、新しい物の定義が同じ（再実行で変わらない）', 'ok', hb1 = hb2));
  res := res || jsonb_build_array(jsonb_build_object('n', '2 回目に流しても、既存の指紋が同じ', 'ok', pg_temp.snap() = snap0));

  -- ===== 3. 空の状態でロールバック → 元に戻る → もう一度段階1 =====
  execute rbsql;
  select count(*) into n from pg_class where relnamespace = 'public'::regnamespace and relname = any (array['bank_accounts','bank_csv_originals','bank_import_files','bank_transactions','bank_transaction_events','bank_account_sync_state','bank_deposit_notes']);
  res := res || jsonb_build_array(jsonb_build_object('n', '空の状態でロールバックを流すと、新しい表が全部消える', 'ok', n = 0, 'i', n));
  select count(*) into n from pg_proc where pronamespace = 'public'::regnamespace and proname = any (array['bank_ledger_admin','bank_store_visible','bank_tx_guard','bank_append_only','bank_import_files_guard','bank_tx_correct','bank_deposit_daily','bank_sync_status']);
  res := res || jsonb_build_array(jsonb_build_object('n', 'ロールバックで新しい関数も全部消える', 'ok', n = 0, 'i', n));
  select count(*) into n from pg_policies where policyname = any (array['bank_accounts_read','bank_csv_originals_tbl_read','bank_import_files_read','bank_transactions_read','bank_tx_events_read','bank_sync_state_read','bank_deposit_notes_read','bank_deposit_notes_write','bank_csv_originals_read','bank_csv_originals_insert']);
  res := res || jsonb_build_array(jsonb_build_object('n', 'ロールバックで新しいポリシーも全部消える', 'ok', n = 0, 'i', n));
  res := res || jsonb_build_array(jsonb_build_object('n', 'ロールバック後、バケットは空・非公開のまま残る（Supabase は直接の削除を禁止。消すなら Storage API）', 'ok', exists (select 1 from storage.buckets where id = 'bank-csv-originals' and not public) and not exists (select 1 from storage.objects where bucket_id = 'bank-csv-originals')));
  res := res || jsonb_build_array(jsonb_build_object('n', 'ロールバック後の既存の指紋が、段階1を流す前と同じ', 'ok', pg_temp.snap() = snap0));
  execute stage1;
  res := res || jsonb_build_array(jsonb_build_object('n', 'ロールバック後にもう一度流すと、前と同じ定義になる', 'ok', pg_temp.bank_defs() = hb1));

  -- ===== 4. 権限の台帳（実際の ACL）=====
  select string_agg(t || ':' || p, ',') into v_err from (
    select t, p from unnest(array['bank_accounts','bank_csv_originals','bank_import_files','bank_transactions','bank_transaction_events','bank_account_sync_state','bank_deposit_notes']) t,
                     unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p
     where has_table_privilege('anon', 'public.' || t, p)) q;
  res := res || jsonb_build_array(jsonb_build_object('n', 'anon は 7 つの表のどの権限も持たない（実際の ACL）', 'ok', v_err is null, 'i', v_err));
  select string_agg(t || ':' || p, ',') into v_err from (
    select t, p from unnest(array['bank_accounts','bank_csv_originals','bank_import_files','bank_transactions','bank_transaction_events','bank_account_sync_state']) t,
                     unnest(array['INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) p
     where has_table_privilege('authenticated', 'public.' || t, p)) q;
  res := res || jsonb_build_array(jsonb_build_object('n', 'authenticated は 6 つの表で「読む」以外の権限を持たない', 'ok', v_err is null, 'i', v_err));
  res := res || jsonb_build_array(jsonb_build_object('n', 'authenticated は 6 つの表を読める権限だけ持つ（RLS で絞られる）', 'ok',
    (select bool_and(has_table_privilege('authenticated', 'public.' || t, 'SELECT')) from unnest(array['bank_accounts','bank_csv_originals','bank_import_files','bank_transactions','bank_transaction_events','bank_account_sync_state','bank_deposit_notes']) t)));
  select string_agg(f || '→' || w, ',') into v_err from (
    select f, w from unnest(array['public.bank_ledger_admin()','public.bank_store_visible(uuid)','public.bank_tx_correct(uuid,jsonb,text)','public.bank_deposit_daily(date,date)','public.bank_sync_status()']) f,
                     unnest(array['anon']) w where has_function_privilege(w, f, 'EXECUTE')) q;
  res := res || jsonb_build_array(jsonb_build_object('n', 'anon は 5 つの公開関数を実行できない（実際の ACL）', 'ok', v_err is null, 'i', v_err));
  select string_agg(f || '→' || w, ',') into v_err from (
    select f, w from unnest(array['public.bank_tx_guard()','public.bank_append_only()','public.bank_import_files_guard()']) f,
                     unnest(array['anon','authenticated']) w where has_function_privilege(w, f, 'EXECUTE')) q;
  res := res || jsonb_build_array(jsonb_build_object('n', 'トリガー用の 3 関数は anon・authenticated から直接呼べない', 'ok', v_err is null, 'i', v_err));
  res := res || jsonb_build_array(jsonb_build_object('n', 'バケット bank-csv-originals は非公開', 'ok', exists (select 1 from storage.buckets where id = 'bank-csv-originals' and not public)));
  select count(*) into n from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'bank\_csv\_originals\_%';
  res := res || jsonb_build_array(jsonb_build_object('n', 'storage.objects の新しいポリシーは 2 つ（読む・入れる。更新・削除は無し）', 'ok', n = 2, 'i', n));

  -- ===== 5. 使い捨てデータ（実店舗を参照するだけ）=====
  -- 店舗ごとに 1 口座・1 明細（金額は店舗の並び順で区別）・1 備考。店舗未確定の口座・明細も 1 つ
  select array_agg(id order by id) into v_ids from public.stores;
  for s in select id, corporation_id, row_number() over (order by id) rn from public.stores loop
    insert into public.bank_accounts (bank_code, login_group, account_no, corporation_id, store_id, store_status)
      values ('paypay', 'verify', 'VERIFY-' || s.rn, s.corporation_id, s.id, 'assigned');
    insert into public.bank_transactions (corporation_id, store_id, txn_date, description, deposit_amount, source_kind, match_status, tx_kind, counts_as_sales_deposit)
      values (s.corporation_id, s.id, date '2026-11-01', 'verify', 1000 + s.rn, 'manual_entry', 'verified', 'atm_deposit', true);
    insert into public.bank_deposit_notes (store_id, note_date, note) values (s.id, date '2026-11-01', 'verify');
  end loop;
  insert into public.bank_accounts (bank_code, login_group, account_no) values ('gmo_aozora', 'verify', 'VERIFY-NONE');
  insert into public.bank_transactions (txn_date, description, deposit_amount, source_kind, match_status, tx_kind, counts_as_sales_deposit)
    values (date '2026-11-01', 'verify-unassigned', 999999, 'manual_entry', 'verified', 'atm_deposit', true);
  select count(*) into n from public.stores;
  res := res || jsonb_build_array(jsonb_build_object('n', '使い捨てデータを入れた（店舗数ぶんの口座・明細・備考）', 'ok', true, 'i', n || ' 店舗'));

  -- ===== 6. 本物のユーザー全員で、見える店舗を期待値と突き合わせる（ユーザー・店舗・チームは変更しない）=====
  v_bad := 0; v_checked := 0; v_err := null;
  for u in select id, role, is_master, is_active, team_id from public.users loop
    -- 期待値（このテストの独立した計算。SQL 本体の関数は使わない）
    if u.is_active and (coalesce(u.is_master, false) or u.role in ('CEO', 'HQ')) then
      v_exp := v_ids;                                                -- 全店
    elsif u.is_active and u.role = 'TEAM' then
      select coalesce(array_agg(distinct x order by x), '{}') into v_exp from (
        select store_id x from public.team_stores where team_id = u.team_id
        union select store_id from public.user_stores where user_id = u.id) q;
    elsif u.is_active and u.role in ('TENCHO', 'SHAIN') then
      select coalesce(array_agg(distinct store_id order by store_id), '{}') into v_exp from public.user_stores where user_id = u.id;
    else
      v_exp := '{}';
    end if;
    v := pg_temp.as_user(u.id, 'authenticated', 'select store_id from public.bank_deposit_daily() order by 1');
    select coalesce(array_agg((x ->> 'store_id')::uuid order by (x ->> 'store_id')::uuid), '{}') into v_act from jsonb_array_elements(v -> 'rows') x;
    v_checked := v_checked + 1;
    if not (v ->> 'ok')::boolean or v_act is distinct from (select coalesce(array_agg(z order by z), '{}') from unnest(v_exp) z) then
      v_bad := v_bad + 1; v_err := coalesce(v_err, '') || u.role || ':' || u.id || ' ';
    end if;
    -- 本部・社長・マスター以外は、台帳・口座・取得履歴・訂正履歴・取得状態・原本の台帳が 0 件
    v2 := pg_temp.as_user(u.id, 'authenticated', 'select (select count(*) from public.bank_accounts) a, (select count(*) from public.bank_csv_originals) o, (select count(*) from public.bank_import_files) f, (select count(*) from public.bank_transactions) t, (select count(*) from public.bank_transaction_events) e, (select count(*) from public.bank_account_sync_state) s');
    if (u.is_active and (coalesce(u.is_master, false) or u.role in ('CEO', 'HQ'))) then
      if not ((v2 ->> 'ok')::boolean and (v2 -> 'rows' -> 0 ->> 'a')::int >= 1 and (v2 -> 'rows' -> 0 ->> 't')::int >= 1) then v_bad := v_bad + 1; v_err := coalesce(v_err, '') || 'admin-read:' || u.id || ' '; end if;
    else
      if not ((v2 ->> 'ok')::boolean and (v2 -> 'rows' -> 0 ->> 'a')::int = 0 and (v2 -> 'rows' -> 0 ->> 't')::int = 0 and (v2 -> 'rows' -> 0 ->> 'o')::int = 0
              and (v2 -> 'rows' -> 0 ->> 'f')::int = 0 and (v2 -> 'rows' -> 0 ->> 'e')::int = 0 and (v2 -> 'rows' -> 0 ->> 's')::int = 0) then
        v_bad := v_bad + 1; v_err := coalesce(v_err, '') || 'ledger-leak:' || u.role || ':' || u.id || ' ';
      end if;
    end if;
    -- 備考・取得状態の見える店舗も、期待値と同じ
    v2 := pg_temp.as_user(u.id, 'authenticated', 'select (select count(*) from public.bank_deposit_notes) n, (select count(*) from public.bank_sync_status()) s');
    if not ((v2 ->> 'ok')::boolean and (v2 -> 'rows' -> 0 ->> 'n')::int = coalesce(array_length(v_exp, 1), 0)
              and (v2 -> 'rows' -> 0 ->> 's')::int = coalesce(array_length(v_exp, 1), 0) + (case when u.is_active and (coalesce(u.is_master, false) or u.role in ('CEO', 'HQ')) then 1 else 0 end)) then
      v_bad := v_bad + 1; v_err := coalesce(v_err, '') || 'notes/sync:' || u.role || ':' || u.id || ' ';
    end if;
  end loop;
  res := res || jsonb_build_array(jsonb_build_object('n', '本物のユーザー全員（' || v_checked || ' 人）: 入金・備考・取得状態で見える店舗が期待値（社長・本部・マスター=全店／チーム長=担当チーム＋所属／店長・社員=所属／アルバイト=なし／無効=なし）と完全に一致し、台帳・口座は本部・社長・マスター以外に 0 件', 'ok', v_bad = 0, 'i', coalesce(v_err, '全員一致')));
  -- 役割ごとの人数（どの役割をテストしたか）
  select jsonb_object_agg(k, c) into v from (select (case when not is_active then 'inactive' when coalesce(is_master, false) then 'master' else role end) k, count(*) c from public.users group by 1) q;
  res := res || jsonb_build_array(jsonb_build_object('n', '（参考）テストした本物のユーザーの内訳', 'ok', true, 'i', v));

  -- ===== 7. 未ログイン（anon）・サービスロール =====
  v := pg_temp.as_user(null, 'anon', 'select count(*) n from public.bank_transactions');
  res := res || jsonb_build_array(jsonb_build_object('n', 'anon: 台帳を読めない（権限エラー）', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.as_user(null, 'anon', 'select * from public.bank_deposit_daily()');
  res := res || jsonb_build_array(jsonb_build_object('n', 'anon: 日次集計の関数を呼べない', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.as_user(null, 'anon', 'select count(*) n from storage.objects where bucket_id = ''bank-csv-originals''');
  res := res || jsonb_build_array(jsonb_build_object('n', 'anon: 原本の置き場を読めない（0 件または拒否）', 'ok', not (v ->> 'ok')::boolean or (v -> 'rows' -> 0 ->> 'n')::int = 0, 'i', v));
  v := pg_temp.as_user(null, 'service_role', 'select (select count(*) from public.bank_transactions) t, (select count(*) from public.bank_deposit_daily()) d');
  res := res || jsonb_build_array(jsonb_build_object('n', 'service_role: 台帳・集計を全部読める（取込ジョブ）', 'ok', (v ->> 'ok')::boolean and (v -> 'rows' -> 0 ->> 't')::int = (select count(*) from public.bank_transactions) and (v -> 'rows' -> 0 ->> 'd')::int = (select count(*) from public.stores), 'i', v));

  -- ===== 8. 本物のユーザーで: 訂正の手続き・直接書き込みの拒否 =====
  select id into v_ceo from public.users where role = 'CEO' and is_active limit 1;
  select id into v_hq from public.users where role = 'HQ' and is_active limit 1;
  select id into v_master from public.users where coalesce(is_master, false) and is_active limit 1;
  select id into v_tencho from public.users where role = 'TENCHO' and is_active limit 1;
  select id into v_al from public.users where role = 'AL' and is_active limit 1;
  select id into v_tx from public.bank_transactions where description = 'verify' order by deposit_amount limit 1;
  select store_id into v_store from public.bank_transactions where id = v_tx;
  v := pg_temp.as_user(v_tencho, 'authenticated', format('select public.bank_tx_correct(%L, ''{"adj_deposit_amount": 5}'', ''x'')', v_tx));
  res := res || jsonb_build_array(jsonb_build_object('n', '店長: 訂正の手続き（bank_tx_correct）を呼べない', 'ok', not (v ->> 'ok')::boolean and v ->> 'err' like '%権限%', 'i', v ->> 'err'));
  v := pg_temp.as_user(v_al, 'authenticated', format('select public.bank_tx_correct(%L, ''{"adj_deposit_amount": 5}'', ''x'')', v_tx));
  res := res || jsonb_build_array(jsonb_build_object('n', 'アルバイト: 訂正の手続きを呼べない', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.as_user(v_ceo, 'authenticated', format('select public.bank_tx_correct(%L, ''{"deposit_amount": 5}'', ''原本を書き換え'')', v_tx));
  res := res || jsonb_build_array(jsonb_build_object('n', '社長: 原本の列（deposit_amount）は訂正の手続きでも変えられない', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.as_user(v_ceo, 'authenticated', format('select public.bank_tx_correct(%L, ''{"adj_deposit_amount": 5}'', '''')', v_tx));
  res := res || jsonb_build_array(jsonb_build_object('n', '社長: 理由が無いと訂正できない', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.as_user(v_ceo, 'authenticated', format('select public.bank_tx_correct(%L, ''{"adj_deposit_amount": 7777}'', ''検証用の訂正'')', v_tx));
  res := res || jsonb_build_array(jsonb_build_object('n', '社長: 理由つきで管理上の訂正値を入れられる', 'ok', (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.as_user(v_ceo, 'authenticated', format('select amount, deposit_count from public.bank_deposit_daily() where store_id = %L', v_store));
  res := res || jsonb_build_array(jsonb_build_object('n', '集計は訂正値（7777）を使い、原本の値は変わらない', 'ok', (v -> 'rows' -> 0 ->> 'amount')::numeric = 7777 and (select deposit_amount from public.bank_transactions where id = v_tx) between 1001 and 5000, 'i', v));
  select count(*) into n from public.bank_transaction_events where transaction_id = v_tx and event_kind = 'correct' and reason = '検証用の訂正' and before_values ? 'adj_deposit_amount';
  res := res || jsonb_build_array(jsonb_build_object('n', '訂正の履歴（修正前・修正後・理由）が残る', 'ok', n = 1, 'i', n));
  v := pg_temp.dml_as(v_ceo, 'authenticated', format('update public.bank_transactions set deposit_amount = 1 where id = %L', v_tx));
  res := res || jsonb_build_array(jsonb_build_object('n', '社長でも、画面（authenticated）から台帳を直接書き換えられない', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.dml_as(v_ceo, 'authenticated', format('delete from public.bank_transactions where id = %L', v_tx));
  res := res || jsonb_build_array(jsonb_build_object('n', '社長でも、画面から台帳を削除できない', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.dml_as(null, 'service_role', format('update public.bank_transactions set deposit_amount = 1 where id = %L', v_tx));
  res := res || jsonb_build_array(jsonb_build_object('n', 'サービスロールでも、原本の列は書き換えられない（守りが効く）', 'ok', not (v ->> 'ok')::boolean and v ->> 'err' like '%変更できません%', 'i', v ->> 'err'));
  v := pg_temp.dml_as(null, 'service_role', format('delete from public.bank_transactions where id = %L', v_tx));
  res := res || jsonb_build_array(jsonb_build_object('n', 'サービスロールでも、台帳を削除できない', 'ok', not (v ->> 'ok')::boolean and v ->> 'err' like '%削除できません%', 'i', v ->> 'err'));
  v := pg_temp.dml_as(v_ceo, 'authenticated', format('insert into public.bank_deposit_notes (store_id, note_date, note) values (%L, date ''2026-11-02'', ''社長の備考'')', v_store));
  res := res || jsonb_build_array(jsonb_build_object('n', '社長: 入金備考を書ける', 'ok', (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.dml_as(v_tencho, 'authenticated', format('insert into public.bank_deposit_notes (store_id, note_date, note) values (%L, date ''2026-11-03'', ''店長の備考'')', v_store));
  res := res || jsonb_build_array(jsonb_build_object('n', '店長: 入金備考は書けない', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));

  -- ===== 9. 法人をまたぐ閲覧: 担当チームに明示的に入れた店舗だけ（チームの割り当て以外は変更しない）=====
  select tu.id, tu.team_id into v_tencho, v_teamid from public.users tu where tu.role = 'TEAM' and tu.is_active and tu.team_id is not null
     and exists (select 1 from public.stores x where x.id <> all (coalesce(public.team_store_ids(tu.team_id), '{}') || coalesce(public.user_store_ids(tu.id), '{}'))) limit 1;
  if v_tencho is not null then
    select x.id into v_other from public.stores x where x.id <> all (coalesce(public.team_store_ids(v_teamid), '{}') || coalesce(public.user_store_ids(v_tencho), '{}')) order by x.id limit 1;
    v := pg_temp.as_user(v_tencho, 'authenticated', format('select public.bank_store_visible(%L) v', v_other));
    res := res || jsonb_build_array(jsonb_build_object('n', 'チーム長（担当外の店 ' || left(v_other::text, 8) || '）: 見えない', 'ok', (v -> 'rows' -> 0 ->> 'v')::boolean = false));
    insert into public.team_stores (team_id, store_id) values (v_teamid, v_other);
    v := pg_temp.as_user(v_tencho, 'authenticated', format('select public.bank_store_visible(%L) v, (select count(*) from public.bank_deposit_daily() where store_id = %L) d', v_other, v_other));
    res := res || jsonb_build_array(jsonb_build_object('n', 'その店を担当チームに明示的に入れると、見える（法人が違っても）', 'ok', (v -> 'rows' -> 0 ->> 'v')::boolean and (v -> 'rows' -> 0 ->> 'd')::int = 1, 'i', v));
    delete from public.team_stores where team_id = v_teamid and store_id = v_other;
    v := pg_temp.as_user(v_tencho, 'authenticated', format('select public.bank_store_visible(%L) v', v_other));
    res := res || jsonb_build_array(jsonb_build_object('n', '担当を外すと、また見えない', 'ok', (v -> 'rows' -> 0 ->> 'v')::boolean = false));
  else
    res := res || jsonb_build_array(jsonb_build_object('n', '（スキップ）担当外の店を持つチーム長が実環境にいない', 'ok', true));
  end if;

  -- ===== 9b. 所属店舗の追加・解除が、閲覧権限にすぐ反映される（実在する社員・店長で。変更は巻き戻される）=====
  select u2.id into v_shain from public.users u2 where u2.role = 'SHAIN' and u2.is_active and not coalesce(u2.is_master, false)
     and exists (select 1 from public.user_stores us where us.user_id = u2.id) limit 1;
  if v_shain is not null then
    select array_agg(store_id order by store_id) into v_exp from public.user_stores where user_id = v_shain;
    select x.id into v_other from public.stores x where x.id <> all (v_exp) order by x.id limit 1;
    v := pg_temp.as_user(v_shain, 'authenticated', format('select public.bank_store_visible(%L) v', v_other));
    res := res || jsonb_build_array(jsonb_build_object('n', '実在の社員: 所属していない店は見えない', 'ok', (v -> 'rows' -> 0 ->> 'v')::boolean = false));
    insert into public.user_stores (user_id, store_id, is_primary) values (v_shain, v_other, false);
    v := pg_temp.as_user(v_shain, 'authenticated', format('select public.bank_store_visible(%L) v, (select count(*) from public.bank_deposit_daily() where store_id = %L) d, (select count(*) from public.bank_deposit_notes where store_id = %L) n', v_other, v_other, v_other));
    res := res || jsonb_build_array(jsonb_build_object('n', '所属を追加すると、その店の入金・備考がすぐ見える', 'ok', (v -> 'rows' -> 0 ->> 'v')::boolean and (v -> 'rows' -> 0 ->> 'd')::int = 1 and (v -> 'rows' -> 0 ->> 'n')::int >= 1, 'i', v));
    delete from public.user_stores where user_id = v_shain and store_id = v_other;
    v := pg_temp.as_user(v_shain, 'authenticated', format('select public.bank_store_visible(%L) v', v_other));
    res := res || jsonb_build_array(jsonb_build_object('n', '所属を解除すると、すぐ見えなくなる', 'ok', (v -> 'rows' -> 0 ->> 'v')::boolean = false));
    delete from public.user_stores where user_id = v_shain;
    v := pg_temp.as_user(v_shain, 'authenticated', 'select (select count(*) from public.bank_deposit_daily()) d, (select count(*) from public.bank_deposit_notes) n, (select count(*) from public.bank_sync_status()) s');
    res := res || jsonb_build_array(jsonb_build_object('n', '所属を全部解除すると、何も見えない', 'ok', (v -> 'rows' -> 0 ->> 'd')::int = 0 and (v -> 'rows' -> 0 ->> 'n')::int = 0 and (v -> 'rows' -> 0 ->> 's')::int = 0, 'i', v));
    v := pg_temp.dml_as(v_shain, 'authenticated', format('insert into public.bank_deposit_notes (store_id, note_date, note) values (%L, date ''2026-11-04'', ''社員の備考'')', v_other));
    res := res || jsonb_build_array(jsonb_build_object('n', '社員: 備考を書けない（閲覧のみ）', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));
    v := pg_temp.as_user(v_shain, 'authenticated', format('select public.bank_tx_correct(%L, ''{"adj_deposit_amount": 5}'', ''x'')', v_tx));
    res := res || jsonb_build_array(jsonb_build_object('n', '社員: 訂正・確定の手続きは使えない', 'ok', not (v ->> 'ok')::boolean and v ->> 'err' like '%権限%', 'i', v ->> 'err'));
  else
    res := res || jsonb_build_array(jsonb_build_object('n', '（スキップ）所属店舗のある社員が実環境にいない', 'ok', true));
  end if;

  -- ===== 10. Storage: 置き場の実ファイル・権限 =====
  begin
    insert into storage.objects (bucket_id, name, metadata) values ('bank-csv-originals', 'verify/seed.csv', '{"size": 10}');
    res := res || jsonb_build_array(jsonb_build_object('n', 'storage.objects にテスト用ファイルの行を入れられた（管理者権限）', 'ok', true));
  exception when others then
    res := res || jsonb_build_array(jsonb_build_object('n', 'storage.objects にテスト用ファイルの行を入れられた（管理者権限）', 'ok', false, 'i', sqlerrm));
  end;
  v := pg_temp.as_user(v_ceo, 'authenticated', 'select name from storage.objects where bucket_id = ''bank-csv-originals''');
  res := res || jsonb_build_array(jsonb_build_object('n', '社長: 原本ファイルを読める', 'ok', (v ->> 'ok')::boolean and jsonb_array_length(v -> 'rows') >= 1, 'i', v ->> 'err'));
  v := pg_temp.as_user(v_hq, 'authenticated', 'select name from storage.objects where bucket_id = ''bank-csv-originals''');
  res := res || jsonb_build_array(jsonb_build_object('n', '本部: 原本ファイルを読める', 'ok', (v ->> 'ok')::boolean and jsonb_array_length(v -> 'rows') >= 1, 'i', v ->> 'err'));
  v := pg_temp.as_user(v_tencho, 'authenticated', 'select name from storage.objects where bucket_id = ''bank-csv-originals''');
  res := res || jsonb_build_array(jsonb_build_object('n', '店長: 原本ファイルは読めない（0 件）', 'ok', (v ->> 'ok')::boolean and jsonb_array_length(v -> 'rows') = 0, 'i', v));
  v := pg_temp.as_user(v_shain, 'authenticated', 'select name from storage.objects where bucket_id = ''bank-csv-originals''');
  res := res || jsonb_build_array(jsonb_build_object('n', '社員: 原本ファイルは読めない（0 件）', 'ok', (v ->> 'ok')::boolean and jsonb_array_length(v -> 'rows') = 0, 'i', v));
  v := pg_temp.as_user(v_al, 'authenticated', 'select name from storage.objects where bucket_id = ''bank-csv-originals''');
  res := res || jsonb_build_array(jsonb_build_object('n', 'アルバイト: 原本ファイルは読めない（0 件）', 'ok', (v ->> 'ok')::boolean and jsonb_array_length(v -> 'rows') = 0, 'i', v));
  v := pg_temp.dml_as(v_ceo, 'authenticated', 'update storage.objects set name = ''hacked.csv'' where bucket_id = ''bank-csv-originals''');
  res := res || jsonb_build_array(jsonb_build_object('n', '社長: 原本ファイルを上書き（更新）できない（0 行または拒否）', 'ok', not (v ->> 'ok')::boolean or (v ->> 'n')::int = 0, 'i', v));
  v := pg_temp.dml_as(v_ceo, 'authenticated', 'delete from storage.objects where bucket_id = ''bank-csv-originals''');
  res := res || jsonb_build_array(jsonb_build_object('n', '社長: 原本ファイルを削除できない（0 行または拒否）', 'ok', not (v ->> 'ok')::boolean or (v ->> 'n')::int = 0, 'i', v));
  select count(*) into n from storage.objects where bucket_id = 'bank-csv-originals' and name = 'verify/seed.csv';
  res := res || jsonb_build_array(jsonb_build_object('n', '上の更新・削除のあとも、ファイルは残っている', 'ok', n = 1));
  v := pg_temp.dml_as(v_ceo, 'authenticated', 'insert into storage.objects (bucket_id, name, metadata) values (''bank-csv-originals'', ''verify/by-ceo.csv'', ''{"size": 1}'')');
  res := res || jsonb_build_array(jsonb_build_object('n', '社長: 原本ファイルを追加できる（手動取込）', 'ok', (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.dml_as(v_tencho, 'authenticated', 'insert into storage.objects (bucket_id, name, metadata) values (''bank-csv-originals'', ''verify/by-tencho.csv'', ''{"size": 1}'')');
  res := res || jsonb_build_array(jsonb_build_object('n', '店長: 原本ファイルを追加できない', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.dml_as(null, 'anon', 'insert into storage.objects (bucket_id, name, metadata) values (''bank-csv-originals'', ''verify/by-anon.csv'', ''{"size": 1}'')');
  res := res || jsonb_build_array(jsonb_build_object('n', 'anon: 原本ファイルを追加できない', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.dml_as(null, 'service_role', 'insert into storage.objects (bucket_id, name, metadata) values (''bank-csv-originals'', ''verify/by-job.csv'', ''{"size": 1}'')');
  res := res || jsonb_build_array(jsonb_build_object('n', 'サービスロール: 原本ファイルを追加できる（取込ジョブ）', 'ok', (v ->> 'ok')::boolean, 'i', v ->> 'err'));

  -- ===== 11. 原本の保存確認（実在・サイズ・読み戻したハッシュ）が、解析・確定の必須条件 =====
  select id into v_acct from public.bank_accounts where account_no = 'VERIFY-1';
  insert into public.bank_csv_originals (id, bank_account_id, file_sha256, size_bytes, storage_path)
    values (gen_random_uuid(), v_acct, v_sha, 100, 'paypay/' || v_acct || '/' || v_sha || '.csv') returning id into v_orig;
  insert into public.bank_import_files (bank_account_id, source, original_id, status) values (v_acct, 'playwright', v_orig, 'stored') returning id into v_if;
  v := pg_temp.dml_as(null, 'service_role', format('update public.bank_import_files set status = ''parsed'', original_verified_at = now(), original_verified_sha256 = %L, original_verified_size = 100 where id = %L', v_sha, v_if));
  res := res || jsonb_build_array(jsonb_build_object('n', '台帳の行とハッシュ記録があっても、置き場に実ファイルが無ければ解析済みにできない', 'ok', not (v ->> 'ok')::boolean and v ->> 'err' like '%置き場%', 'i', v ->> 'err'));
  insert into storage.objects (bucket_id, name, metadata) values ('bank-csv-originals', 'paypay/' || v_acct || '/' || v_sha || '.csv', '{"size": 99}');
  v := pg_temp.dml_as(null, 'service_role', format('update public.bank_import_files set status = ''parsed'', original_verified_at = now(), original_verified_sha256 = %L, original_verified_size = 100 where id = %L', v_sha, v_if));
  res := res || jsonb_build_array(jsonb_build_object('n', '置き場のサイズが台帳と違うと、解析済みにできない', 'ok', not (v ->> 'ok')::boolean and v ->> 'err' like '%サイズ%', 'i', v ->> 'err'));
  update storage.objects set metadata = '{"size": 100}' where bucket_id = 'bank-csv-originals' and name = 'paypay/' || v_acct || '/' || v_sha || '.csv';
  v := pg_temp.dml_as(null, 'service_role', format('update public.bank_import_files set status = ''parsed'' where id = %L', v_if));
  res := res || jsonb_build_array(jsonb_build_object('n', '実ファイルがあっても、読み戻した確認（ハッシュ・サイズ）が無ければ解析済みにできない', 'ok', not (v ->> 'ok')::boolean and v ->> 'err' like '%読み戻した確認%', 'i', v ->> 'err'));
  v := pg_temp.dml_as(null, 'service_role', format('update public.bank_import_files set status = ''parsed'', original_verified_at = now(), original_verified_sha256 = repeat(''b'', 64), original_verified_size = 100 where id = %L', v_if));
  res := res || jsonb_build_array(jsonb_build_object('n', '読み戻したハッシュが台帳と違うと、解析済みにできない', 'ok', not (v ->> 'ok')::boolean and v ->> 'err' like '%一致しません%', 'i', v ->> 'err'));
  v := pg_temp.dml_as(null, 'service_role', format('update public.bank_import_files set status = ''committed'' where id = %L', v_if));
  res := res || jsonb_build_array(jsonb_build_object('n', '確認が済む前に、確定に飛ばすこともできない', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.dml_as(null, 'service_role', format('update public.bank_import_files set status = ''parsed'', original_verified_at = now(), original_verified_sha256 = %L, original_verified_size = 100 where id = %L', v_sha, v_if));
  res := res || jsonb_build_array(jsonb_build_object('n', '実ファイルが実在し、サイズ・読み戻したハッシュが台帳と一致すれば、解析済みにできる（サービスロールで）', 'ok', (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.dml_as(null, 'service_role', format('update public.bank_import_files set status = ''committed'', committed_at = now() where id = %L', v_if));
  res := res || jsonb_build_array(jsonb_build_object('n', '取込途中の明細が無ければ、確定できる', 'ok', (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.dml_as(v_ceo, 'authenticated', format('update public.bank_import_files set status = ''stored'' where id = %L', v_if));
  res := res || jsonb_build_array(jsonb_build_object('n', '社長でも、画面から取得履歴を書き換えられない', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));
  v := pg_temp.dml_as(null, 'service_role', format('insert into public.bank_import_files (bank_account_id, source, status) values (%L, ''playwright'', ''committed'')', v_acct));
  res := res || jsonb_build_array(jsonb_build_object('n', '最初から「確定」で取得履歴を作れない', 'ok', not (v ->> 'ok')::boolean, 'i', v ->> 'err'));

  -- ===== 12. データが入った状態では、ロールバックが何も消さずに止まる =====
  begin
    execute rbsql;
    res := res || jsonb_build_array(jsonb_build_object('n', 'データが入っていると、ロールバックは止まる', 'ok', false, 'i', '止まらなかった'));
  exception when others then
    select count(*) into n from pg_class where relnamespace = 'public'::regnamespace and relname = any (array['bank_accounts','bank_csv_originals','bank_import_files','bank_transactions','bank_transaction_events','bank_account_sync_state','bank_deposit_notes']) and relkind = 'r';
    res := res || jsonb_build_array(jsonb_build_object('n', 'データが入っていると、ロールバックは止まり、表は 7 つ残る', 'ok', n = 7 and sqlerrm like '%取り消しを中止%', 'i', sqlerrm));
  end;

  -- ===== 13. 巻き戻しの前に、既存への影響がなかったことをもう一度 =====
  res := res || jsonb_build_array(jsonb_build_object('n', '全テストのあとも、既存の指紋が段階1を流す前と同じ', 'ok', pg_temp.snap() = snap0));
  res := res || jsonb_build_array(jsonb_build_object('n', '所要時間（秒）', 'ok', true, 'i', round(extract(epoch from clock_timestamp() - t0)::numeric, 2)));

  -- ===== 7. 最後に必ず例外で全部巻き戻す =====
  raise exception '#VERIFY-RESULT#%', res::text;
end
$__verify__$;
"""
body = body.replace('__STAGE1__', STAGE1).replace('__ROLLBACK__', ROLLBACK)

if '--print' in sys.argv:
    print(body); sys.exit(0)

pat = open(os.path.expanduser('~/.config/ns-portal/supabase_pat')).read().strip()
req = urllib.request.Request(
    'https://api.supabase.com/v1/projects/uuvsxzhpxtghojoubjcc/database/query',
    data=json.dumps({'query': body}).encode(),
    headers={'Authorization': 'Bearer ' + pat, 'Content-Type': 'application/json', 'User-Agent': 'curl/8'})
t = time.time()
try:
    out = urllib.request.urlopen(req, timeout=300).read().decode()
    print('想定外: 例外で終わらず成功した（本来は必ず例外で巻き戻る）:', out[:500]); sys.exit(2)
except urllib.error.HTTPError as e:
    raw = e.read().decode()
try:
    msg = json.loads(raw).get('message', raw)
except Exception:
    msg = raw
m = re.search(r'#VERIFY-RESULT#(\[.*\])', msg, re.S)
if not m:
    print('検証が結果まで届きませんでした（エラー）:'); print(msg[:3000]); sys.exit(1)
res = json.loads(m.group(1))
ng = [r for r in res if not r.get('ok')]
for r in res:
    print(('  ✅ ' if r.get('ok') else '  ❌ ') + r['n'] + ((' → ' + str(r['i'])[:300]) if r.get('i') not in (None, '') and (not r.get('ok') or r['n'].startswith('（') or '所要' in r['n'] or '使い捨て' in r['n']) else ''))
print('\n==== 実環境の事前検証: %d 件 OK ／ %d 件 NG（全て巻き戻し済み・%.1f 秒）====' % (len(res) - len(ng), len(ng), time.time() - t))
sys.exit(1 if ng else 0)
