-- 銀行入金明細の正本（Supabase）— 段階2: 取込の関数（原本の保存確認つき・重複しない取込）
-- 作成: 2026-11-28　状態: **下書き（未適用）**。本番への適用は、ユーザーが SQL の中身を確認して承認してから。
-- 前提: 段階1（2026-11-27_bank_ledger_stage1.sql）が適用済み。段階1のファイルは編集しない（変更はこの新しいファイルで）。
-- 設計: docs/計画書_銀行入金の正本化_段階2_2026-11-28.html ／ テスト: tools/bank-ledger-test/（PGlite と、実環境の「流して必ず巻き戻す」検証）
--
-- 【この SQL がやること】取込ジョブ（サービスロール）だけが呼べる関数を 7 つ「足す」だけ。表・列・既存の関数・ポリシーは変えない。
-- 【この SQL がやらないこと】データの追加・変更（関数を作るだけ）、画面・GAS・BigQuery・既存の取込の変更。
-- 【ロールバック】2026-11-28_bank_ledger_stage2_ROLLBACK.sql（関数を消すだけ。データは触らない）。
-- 【再実行】create or replace なので、何度流しても同じ。
--
-- 取込の流れ（1 回の取得）:
--   bank_import_register → （ジョブが原本を Storage へ保存）→ bank_import_attach_original → （ジョブが読み戻して SHA-256・サイズを計算）
--   → bank_import_record_verification → bank_import_ingest（ここで段階1の守りが「実ファイルの実在・サイズ・ハッシュの一致」を確かめる）
--   → bank_import_commit。どこかで失敗したら bank_import_fail（確定済みの数字は変えず、失敗を取得履歴と取得状態に残す）。
-- 重複判定の目印（dedupe_key）は、CSV を読むジョブ側（銀行ごとのルール）が作って渡す。DB は「同じ口座・同じ目印は 1 行だけ」を一意制約で守る
--   → 同じ明細を何回取り直しても、行は増えない（2 回目以降は rows_dup に数えるだけ）。識別できない行は、理由つきで保留（held）にして入れる。

-- 共通: サービスロール（取込ジョブ）だけ
create or replace function public.bank_assert_service()
returns void language plpgsql stable as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception '取込ジョブ（サービスロール）だけが呼べる関数です';
  end if;
end $$;
revoke all on function public.bank_assert_service() from public, anon, authenticated;

-- 1. 口座の登録・更新（口座番号は表にだけ置く。リポジトリには書かない）。店舗が未定でも登録できる（unassigned）。
--    すでにある口座の店舗割り当ては、null で上書きしない。
create or replace function public.bank_account_upsert(p_bank text, p_login_group text, p_account_no text, p_display_name text default null, p_store uuid default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_corp uuid;
begin
  perform public.bank_assert_service();
  if p_store is not null then select s.corporation_id into v_corp from public.stores s where s.id = p_store; end if;
  insert into public.bank_accounts (bank_code, login_group, account_no, display_name, store_id, corporation_id, store_status)
  values (p_bank, p_login_group, p_account_no, p_display_name, p_store, v_corp, case when p_store is null then 'unassigned' else 'assigned' end)
  on conflict (bank_code, account_no) do update set
    login_group    = excluded.login_group,
    display_name   = coalesce(excluded.display_name, public.bank_accounts.display_name),
    store_id       = coalesce(excluded.store_id, public.bank_accounts.store_id),
    corporation_id = coalesce(excluded.corporation_id, public.bank_accounts.corporation_id),
    store_status   = case when coalesce(excluded.store_id, public.bank_accounts.store_id) is null then 'unassigned' else 'assigned' end,
    updated_at     = now()
  returning id into v_id;
  return v_id;
end $$;

-- 2. 取得の登録。同じ口座の取込は 1 つずつ（実行中の印がある間は、新しい取込を始められない。30 分で期限切れ）。
create or replace function public.bank_import_register(p_account uuid, p_source text, p_file_name text default null,
                                                       p_period_from date default null, p_period_to date default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_state public.bank_account_sync_state%rowtype; v_id uuid;
begin
  perform public.bank_assert_service();
  if not exists (select 1 from public.bank_accounts where id = p_account and is_active) then raise exception '口座が見つかりません（または無効）'; end if;
  insert into public.bank_account_sync_state (bank_account_id) values (p_account) on conflict (bank_account_id) do nothing;
  select * into v_state from public.bank_account_sync_state where bank_account_id = p_account for update;
  if v_state.status = 'running' and v_state.last_attempt_at > now() - interval '30 minutes' then
    raise exception 'この口座の取込がすでに実行中です（%）', v_state.last_attempt_at;
  end if;
  update public.bank_account_sync_state set status = 'running', last_attempt_at = now(), updated_at = now() where bank_account_id = p_account;
  insert into public.bank_import_files (bank_account_id, source, file_name, period_from, period_to, status)
  values (p_account, p_source, p_file_name, p_period_from, p_period_to, 'registered') returning id into v_id;
  return v_id;
end $$;

-- 3. 原本の台帳に登録（同じ口座・同じ SHA-256 の原本があれば、それを指す＝取り直し）。置き場所は SHA-256 から決まる。
--    返す storage_bucket / storage_path に、ジョブが原本を保存する（上書きはしない）。保存の実在は、解析に進むときに DB が確かめる。
create or replace function public.bank_import_attach_original(p_import uuid, p_sha256 text, p_size integer, p_content_type text default 'text/csv')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_imp public.bank_import_files%rowtype; v_acct public.bank_accounts%rowtype; v_path text; v_orig public.bank_csv_originals%rowtype; v_reused boolean := false;
begin
  perform public.bank_assert_service();
  select * into v_imp from public.bank_import_files where id = p_import for update;
  if not found then raise exception '取得履歴が見つかりません'; end if;
  if v_imp.status <> 'registered' then raise exception '登録済みの取得履歴だけ、原本を結べます（いまの状態: %）', v_imp.status; end if;
  select * into v_acct from public.bank_accounts where id = v_imp.bank_account_id;
  v_path := v_acct.bank_code || '/' || v_acct.id || '/' || p_sha256 || '.csv';
  select * into v_orig from public.bank_csv_originals where bank_account_id = v_acct.id and file_sha256 = p_sha256;
  if found then
    v_reused := true;
    if v_orig.size_bytes <> p_size then raise exception '同じ SHA-256 の原本とサイズが違います（台帳 % / 今回 %）', v_orig.size_bytes, p_size; end if;
  else
    insert into public.bank_csv_originals (bank_account_id, file_sha256, size_bytes, content_type, first_file_name, storage_path)
    values (v_acct.id, p_sha256, p_size, p_content_type, v_imp.file_name, v_path) returning * into v_orig;
  end if;
  update public.bank_import_files set original_id = v_orig.id, original_reused = v_reused, status = 'stored' where id = p_import;
  return jsonb_build_object('original_id', v_orig.id, 'storage_bucket', v_orig.storage_bucket, 'storage_path', v_orig.storage_path, 'reused', v_reused);
end $$;

-- 4. 読み戻して計算した SHA-256・サイズを記録（あとから変えられない）。台帳の値と違えば、ここで止める。
create or replace function public.bank_import_record_verification(p_import uuid, p_sha256 text, p_size integer)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_imp public.bank_import_files%rowtype; v_orig public.bank_csv_originals%rowtype;
begin
  perform public.bank_assert_service();
  select * into v_imp from public.bank_import_files where id = p_import for update;
  if not found then raise exception '取得履歴が見つかりません'; end if;
  if v_imp.status <> 'stored' then raise exception '保存済みの取得履歴だけ、確認結果を記録できます（いまの状態: %）', v_imp.status; end if;
  select * into v_orig from public.bank_csv_originals where id = v_imp.original_id;
  if p_sha256 is distinct from v_orig.file_sha256 or p_size is distinct from v_orig.size_bytes then
    raise exception '読み戻した原本のハッシュ・サイズが台帳と一致しません（取り込みません）';
  end if;
  update public.bank_import_files set original_verified_at = now(), original_verified_sha256 = p_sha256, original_verified_size = p_size where id = p_import;
end $$;

-- 5. 明細の取込。1 つのトランザクション（途中で失敗したら、何も残らない）。
--    p_rows: [{date, time, desc, dep, wd, bal, key, basis, hold_reason}] — key は重複判定の目印（ジョブが銀行ごとのルールで作る）。
--      hold_reason があれば、その行は保留（held）で入る（識別できない・残高の鎖が切れている等）。
--    ・key がすでに同じ口座にあれば、何もしない（rows_dup）＝同じ明細を何回取っても増えない。
--    ・取得期間の中にある既存の照合済みの行が、今回の CSV に 1 つも無いもの（overlap_missing）があれば、新しい行は保留で入れる（既存と食い違うため）。
--    ・分類（ATM 入金など）は、いまの入金管理の考え方をそのまま写す: 入金で摘要に ATM を含むものだけを売上入金として数える。
--    段階1の守りにより、原本が置き場に実在し、サイズ・読み戻したハッシュが台帳と一致していなければ、ここ（解析済みへの移行）で止まる。
create or replace function public.bank_import_ingest(p_import uuid, p_rows jsonb, p_chain_ok boolean default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_imp public.bank_import_files%rowtype; v_acct public.bank_accounts%rowtype;
  r jsonb; v_key text; v_hold text; v_status text; v_kind text; v_counts boolean; v_dep bigint; v_wd bigint; v_desc text; v_n bigint;
  v_total int := 0; v_new int := 0; v_dup int := 0; v_held int := 0; v_held_dup int := 0;
  v_min date; v_max date; v_keys text[]; v_overlap int := 0;
begin
  perform public.bank_assert_service();
  select * into v_imp from public.bank_import_files where id = p_import for update;
  if not found then raise exception '取得履歴が見つかりません'; end if;
  if v_imp.status <> 'stored' then raise exception '保存済みの取得履歴だけ、取り込めます（いまの状態: %）', v_imp.status; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'p_rows は配列で渡してください'; end if;
  select * into v_acct from public.bank_accounts where id = v_imp.bank_account_id;
  -- 解析済みへ（段階1のトリガーが、実ファイルの実在・サイズ・読み戻しハッシュの一致を確かめる。満たさなければ、ここで例外）
  update public.bank_import_files set status = 'parsed' where id = p_import;

  select min((x ->> 'date')::date), max((x ->> 'date')::date), array_agg(x ->> 'key') filter (where coalesce(x ->> 'key', '') <> '')
    into v_min, v_max, v_keys from jsonb_array_elements(p_rows) x;
  if v_min is not null then
    select count(*) into v_overlap from public.bank_transactions t
     where t.bank_account_id = v_acct.id and t.source_kind in ('playwright', 'manual_csv') and t.match_status = 'verified'
       and t.txn_date between v_min and v_max and t.dedupe_key is not null
       and not (t.dedupe_key = any (coalesce(v_keys, '{}'::text[])));
  end if;

  for r in select x from jsonb_array_elements(p_rows) x loop
    v_total := v_total + 1;
    v_key := nullif(r ->> 'key', '');
    v_hold := nullif(r ->> 'hold_reason', '');
    v_dep := coalesce((r ->> 'dep')::bigint, 0); v_wd := coalesce((r ->> 'wd')::bigint, 0); v_desc := coalesce(r ->> 'desc', '');
    if v_key is null and v_hold is null then v_hold := '重複判定の目印が作れないため'; end if;
    if v_hold is null and v_overlap > 0 then v_hold := '取得期間の重なりが既存の明細と一致しないため（既存の照合済み ' || v_overlap || ' 件が今回の CSV に無い）'; end if;
    v_status := case when v_hold is null then 'verified' else 'held' end;
    -- 分類（いまの考え方: 入金で摘要に ATM を含むものだけが売上入金。利息・各種振込・出金は数えない）
    if v_dep > 0 and v_desc ~ '(ATM|ＡＴＭ)' then v_kind := 'atm_deposit'; v_counts := true;
    elsif v_dep > 0 and v_desc ~ '(利息|利子)' then v_kind := 'interest'; v_counts := false;
    elsif v_dep > 0 then v_kind := 'transfer_in'; v_counts := false;
    elsif v_wd > 0 and v_desc ~ '(手数料)' then v_kind := 'fee'; v_counts := false;
    elsif v_wd > 0 then v_kind := 'transfer_out'; v_counts := false;
    else v_kind := 'other'; v_counts := false; end if;
    insert into public.bank_transactions (bank_account_id, corporation_id, store_id, txn_date, txn_time, description, deposit_amount, withdrawal_amount, balance,
                                          source_kind, import_file_id, dedupe_key, identity_basis, match_status, hold_reason, tx_kind, counts_as_sales_deposit)
    values (v_acct.id, v_acct.corporation_id, v_acct.store_id, (r ->> 'date')::date, nullif(r ->> 'time', '')::time, v_desc, v_dep, v_wd, nullif(r ->> 'bal', '')::bigint,
            v_imp.source, p_import, v_key, coalesce(nullif(r ->> 'basis', ''), 'none'), v_status, v_hold, v_kind, v_counts)
    on conflict (bank_account_id, dedupe_key) where dedupe_key is not null do nothing;
    get diagnostics v_n = row_count;
    if v_n = 1 then
      if v_status = 'held' then v_held := v_held + 1; else v_new := v_new + 1; end if;
    else
      v_dup := v_dup + 1;
    end if;
  end loop;

  update public.bank_import_files set rows_total = v_total, rows_new = v_new, rows_dup = v_dup, rows_held = v_held,
         balance_chain_ok = p_chain_ok, period_from = coalesce(period_from, v_min), period_to = coalesce(period_to, v_max) where id = p_import;
  return jsonb_build_object('rows_total', v_total, 'rows_new', v_new, 'rows_dup', v_dup, 'rows_held', v_held, 'overlap_missing', v_overlap,
                            'period_from', v_min, 'period_to', v_max);
end $$;

-- 6. 確定。取込途中の明細が残っていれば、段階1の守りが拒否する。取得状態（最終成功・取得済みの最新日付）を更新する。
create or replace function public.bank_import_commit(p_import uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_imp public.bank_import_files%rowtype; v_max date;
begin
  perform public.bank_assert_service();
  select * into v_imp from public.bank_import_files where id = p_import for update;
  if not found then raise exception '取得履歴が見つかりません'; end if;
  if v_imp.status <> 'parsed' then raise exception '解析済みの取得履歴だけ、確定できます（いまの状態: %）', v_imp.status; end if;
  update public.bank_import_files set status = 'committed', committed_at = now(), as_of = now() where id = p_import;
  select max(txn_date) into v_max from public.bank_transactions where bank_account_id = v_imp.bank_account_id and match_status in ('verified', 'held');
  update public.bank_account_sync_state set status = 'ok', last_success_at = now(), last_success_file_id = p_import, covers_through = v_max,
         last_error = null, last_error_at = null, updated_at = now() where bank_account_id = v_imp.bank_account_id;
  return jsonb_build_object('committed', true, 'covers_through', v_max);
end $$;

-- 7. 失敗の記録。確定済みの取得履歴は変えない。取込済みの数字は消さない・0 で上書きしない（失敗は取得状態に残るだけ）。
create or replace function public.bank_import_fail(p_import uuid, p_error text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_imp public.bank_import_files%rowtype;
begin
  perform public.bank_assert_service();
  select * into v_imp from public.bank_import_files where id = p_import for update;
  if not found then raise exception '取得履歴が見つかりません'; end if;
  if v_imp.status = 'committed' then raise exception '確定済みの取得履歴は失敗にできません'; end if;
  update public.bank_import_files set status = 'failed', error = left(coalesce(p_error, '原因不明'), 500), error_at = now() where id = p_import;
  update public.bank_account_sync_state set status = 'error', last_error = left(coalesce(p_error, '原因不明'), 500), last_error_at = now(), updated_at = now()
   where bank_account_id = v_imp.bank_account_id;
end $$;

-- 実行権限: サービスロールだけ（画面からも、ログイン済みの人からも呼べない）
revoke all on function public.bank_account_upsert(text, text, text, text, uuid) from public, anon, authenticated;
revoke all on function public.bank_import_register(uuid, text, text, date, date) from public, anon, authenticated;
revoke all on function public.bank_import_attach_original(uuid, text, integer, text) from public, anon, authenticated;
revoke all on function public.bank_import_record_verification(uuid, text, integer) from public, anon, authenticated;
revoke all on function public.bank_import_ingest(uuid, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.bank_import_commit(uuid) from public, anon, authenticated;
revoke all on function public.bank_import_fail(uuid, text) from public, anon, authenticated;
grant execute on function public.bank_account_upsert(text, text, text, text, uuid) to service_role;
grant execute on function public.bank_import_register(uuid, text, text, date, date) to service_role;
grant execute on function public.bank_import_attach_original(uuid, text, integer, text) to service_role;
grant execute on function public.bank_import_record_verification(uuid, text, integer) to service_role;
grant execute on function public.bank_import_ingest(uuid, jsonb, boolean) to service_role;
grant execute on function public.bank_import_commit(uuid) to service_role;
grant execute on function public.bank_import_fail(uuid, text) to service_role;
