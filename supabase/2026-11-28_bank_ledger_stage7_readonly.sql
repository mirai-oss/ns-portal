-- 銀行台帳: 全法人の「閲覧専用」権限（2026-11-28）。状態: 下書き（未適用）。適用は社長の承認後（本部 2 人への付与の前提）。
-- 前提: 段階5・6 適用済み。
-- 【目的】全法人の閲覧権限（bank_ledger_global_users）を付与された本部は、明細・口座・原本・集計を全法人ぶん「読める」が、
--   銀行明細の修正・店舗や法人の紐付け・紐付けの取り消し・運営法人の変更・差異の判断・権限の付与や取り消し・入金備考の書き込みは「できない」ようにする。
-- 【やること】付与の記録に read_only 列を足す（既定 true＝付与された人は閲覧専用）。書き込み系の関数・ポリシーに、閲覧専用でないことの確認 bank_write_ok() を足す。
-- 【変わらないこと】社長・マスター（付与の記録が無い）、法人を限定された本部（自法人の分の従来の操作）、サービスロール（取込・照合）の動きは変わらない。読み取りの範囲も変わらない。
-- 【ロールバック】_ROLLBACK.sql（付与の記録が 1 件でもあると止まる＝戻すと閲覧専用の人が書き込めるようになってしまうため。先に付与を取り消す）。
alter table public.bank_ledger_global_users add column if not exists read_only boolean not null default true;
create or replace function public.bank_write_ok()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select not exists (select 1 from public.bank_ledger_global_users g where g.user_id = auth.uid() and g.revoked_at is null and g.read_only)
$$;
revoke all on function public.bank_write_ok() from public, anon;
grant execute on function public.bank_write_ok() to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.bank_tx_correct(p_id uuid, p_changes jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_old public.bank_transactions%rowtype;
  v_allowed text[] := array['store_id','tx_kind','counts_as_sales_deposit','confirm_status',
                            'adj_txn_date','adj_description','adj_deposit_amount','adj_withdrawal_amount'];
  k text;
  v_name text;
  v_corp uuid;
begin
  if not (public.bank_ledger_admin() and public.bank_write_ok()) then raise exception '権限がありません（閲覧専用の権限では、修正・紐付け・権限の操作はできません）'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '訂正の理由が必要です'; end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then raise exception '変更内容がありません'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not (k = any (v_allowed)) then raise exception '変更できない項目です（原本の事実は変えられません）: %', k; end if;
  end loop;
  select * into v_old from public.bank_transactions where id = p_id for update;
  if not found then raise exception '明細が見つかりません'; end if;
  if not public.bank_corp_ok(v_old.corporation_id) then raise exception '権限がありません（この明細の法人を見る権限がありません）'; end if;
  if p_changes ? 'store_id' then
    v_corp := public.store_corporation_on(nullif(p_changes ->> 'store_id', '')::uuid, coalesce(v_old.adj_txn_date, v_old.txn_date));
    if nullif(p_changes ->> 'store_id', '') is not null and not public.bank_corp_ok(v_corp) then raise exception '権限がありません（付け替え先の店舗の法人を見る権限がありません）'; end if;
  end if;
  select coalesce(u.name, u.id::text) into v_name from public.users u where u.id = auth.uid();
  perform set_config('app.bank_correction', 'on', true);
  perform set_config('app.bank_reason', btrim(p_reason), true);
  perform set_config('app.bank_actor', coalesce(v_name, 'user'), true);
  update public.bank_transactions t set
    store_id                = case when p_changes ? 'store_id' then nullif(p_changes ->> 'store_id', '')::uuid else t.store_id end,
    corporation_id          = case when p_changes ? 'store_id' then v_corp else t.corporation_id end,
    tx_kind                 = case when p_changes ? 'tx_kind' then p_changes ->> 'tx_kind' else t.tx_kind end,
    counts_as_sales_deposit = case when p_changes ? 'counts_as_sales_deposit' then (p_changes ->> 'counts_as_sales_deposit')::boolean else t.counts_as_sales_deposit end,
    adj_txn_date            = case when p_changes ? 'adj_txn_date' then nullif(p_changes ->> 'adj_txn_date', '')::date else t.adj_txn_date end,
    adj_description         = case when p_changes ? 'adj_description' then p_changes ->> 'adj_description' else t.adj_description end,
    adj_deposit_amount      = case when p_changes ? 'adj_deposit_amount' then nullif(p_changes ->> 'adj_deposit_amount', '')::bigint else t.adj_deposit_amount end,
    adj_withdrawal_amount   = case when p_changes ? 'adj_withdrawal_amount' then nullif(p_changes ->> 'adj_withdrawal_amount', '')::bigint else t.adj_withdrawal_amount end,
    confirm_status          = case when p_changes ? 'confirm_status' then p_changes ->> 'confirm_status' else t.confirm_status end,
    confirmed_at            = case when p_changes ? 'confirm_status' then (case when p_changes ->> 'confirm_status' = 'confirmed' then now() else null end) else t.confirmed_at end,
    confirmed_by            = case when p_changes ? 'confirm_status' then (case when p_changes ->> 'confirm_status' = 'confirmed' then auth.uid() else null end) else t.confirmed_by end
  where t.id = p_id;
  -- このトランザクションの外へ設定を漏らさない
  perform set_config('app.bank_correction', '', true);
  perform set_config('app.bank_reason', '', true);
  perform set_config('app.bank_actor', '', true);
  return jsonb_build_object('ok', true, 'id', p_id);
end $function$;

CREATE OR REPLACE FUNCTION public.bank_account_assign_store(p_account uuid, p_store uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_acct public.bank_accounts%rowtype; v_name text; v_hist uuid; v_n int := 0; v_skipped int := 0; v_corp uuid;
begin
  if not (public.bank_ledger_admin() and public.bank_write_ok()) then raise exception '権限がありません（閲覧専用の権限では、修正・紐付け・権限の操作はできません）'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由が必要です'; end if;
  select * into v_acct from public.bank_accounts where id = p_account for update;
  if not found then raise exception '口座が見つかりません'; end if;
  if not public.bank_corp_ok(v_acct.corporation_id) then raise exception '権限がありません（この口座の法人を見る権限がありません）'; end if;
  if v_acct.usage_mode = 'multi' then raise exception '複数店舗で共有する口座は、口座単位では店舗を決められません。取引単位で紐付けてください'; end if;
  if not exists (select 1 from public.stores where id = p_store) then raise exception '店舗が見つかりません'; end if;
  if v_acct.store_id is not null and v_acct.store_id <> p_store then raise exception 'すでに別の店舗（%）が紐付いています。付け替えは、履歴の取り消しから行ってください', v_acct.store_id; end if;
  select coalesce(u.name, u.id::text) into v_name from public.users u where u.id = auth.uid();
  v_corp := public.store_corporation_on(p_store, current_date);
  if not public.bank_corp_ok(v_corp) then raise exception '権限がありません（紐付け先の店舗の運営法人を見る権限がありません）'; end if;
  insert into public.bank_assignment_history (kind, action, account_id, before_values, after_values, reason, actor_id, actor_label)
    values ('account', 'assign', p_account, jsonb_build_object('store_id', v_acct.store_id, 'corporation_id', v_acct.corporation_id, 'store_status', v_acct.store_status),
            jsonb_build_object('store_id', p_store, 'corporation_id', v_corp, 'store_status', 'assigned'), btrim(p_reason), auth.uid(), coalesce(v_name, 'user')) returning id into v_hist;
  update public.bank_accounts set store_id = p_store, corporation_id = coalesce(v_corp, corporation_id), store_status = 'assigned', updated_at = now() where id = p_account;
  perform set_config('app.bank_reason', btrim(p_reason), true); perform set_config('app.bank_actor', coalesce(v_name, 'user'), true);
  with tgt as (select t.id, t.corporation_id old_corp, public.store_corporation_on(p_store, t.txn_date) new_corp from public.bank_transactions t
                where t.bank_account_id = p_account and t.store_id is null and t.confirm_status = 'open' and not t.is_adjusted and ((select public.bank_global_admin()) or t.corporation_id = any (coalesce((select public.bank_allowed_corp_ids()), '{}'::uuid[])))),
       hist as (insert into public.bank_assignment_history (kind, action, account_id, transaction_id, parent_id, before_values, after_values, reason, actor_id, actor_label)
                select 'transaction', 'assign', p_account, tgt.id, v_hist, jsonb_build_object('store_id', null, 'corporation_id', tgt.old_corp),
                       jsonb_build_object('store_id', p_store, 'corporation_id', coalesce(tgt.new_corp, tgt.old_corp)), btrim(p_reason), auth.uid(), coalesce(v_name, 'user') from tgt returning transaction_id),
       upd as (update public.bank_transactions t set store_id = p_store, corporation_id = coalesce(tgt.new_corp, t.corporation_id) from tgt where t.id = tgt.id returning t.id)
  select count(*) into v_n from upd;
  select count(*) into v_skipped from public.bank_transactions t where t.bank_account_id = p_account and t.store_id is null;
  perform set_config('app.bank_reason', '', true); perform set_config('app.bank_actor', '', true);
  return jsonb_build_object('ok', true, 'history_id', v_hist, 'updated_transactions', v_n, 'skipped_unassigned_confirmed_or_adjusted', v_skipped);
end $function$;

CREATE OR REPLACE FUNCTION public.bank_tx_assign_store(p_tx_ids uuid[], p_store uuid, p_reason text, p_allow_change boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_name text; v_n int := 0; v_skip int := 0;
begin
  if not (public.bank_ledger_admin() and public.bank_write_ok()) then raise exception '権限がありません（閲覧専用の権限では、修正・紐付け・権限の操作はできません）'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由が必要です'; end if;
  if coalesce(array_length(p_tx_ids, 1), 0) = 0 then raise exception '対象が空です'; end if;
  if not exists (select 1 from public.stores where id = p_store) then raise exception '店舗が見つかりません'; end if;
  select coalesce(u.name, u.id::text) into v_name from public.users u where u.id = auth.uid();
  perform set_config('app.bank_reason', btrim(p_reason), true); perform set_config('app.bank_actor', coalesce(v_name, 'user'), true);
  with tgt as (select t.id, t.bank_account_id, t.store_id old_store, t.corporation_id old_corp, public.store_corporation_on(p_store, t.txn_date) new_corp
                 from public.bank_transactions t where t.id = any (p_tx_ids) and t.confirm_status = 'open' and not t.is_adjusted
                  and (t.store_id is null or (p_allow_change and t.store_id <> p_store))
                  and ((select public.bank_global_admin()) or t.corporation_id = any (coalesce((select public.bank_allowed_corp_ids()), '{}'::uuid[]))) and public.bank_corp_ok(public.store_corporation_on(p_store, t.txn_date))),
       hist as (insert into public.bank_assignment_history (kind, action, account_id, transaction_id, before_values, after_values, reason, actor_id, actor_label)
                select 'transaction', case when tgt.old_store is null then 'assign' else 'reassign' end, tgt.bank_account_id, tgt.id,
                       jsonb_build_object('store_id', tgt.old_store, 'corporation_id', tgt.old_corp), jsonb_build_object('store_id', p_store, 'corporation_id', coalesce(tgt.new_corp, tgt.old_corp)),
                       btrim(p_reason), auth.uid(), coalesce(v_name, 'user') from tgt returning transaction_id),
       upd as (update public.bank_transactions t set store_id = p_store, corporation_id = coalesce(tgt.new_corp, t.corporation_id) from tgt where t.id = tgt.id returning t.id)
  select count(*) into v_n from upd;
  v_skip := coalesce(array_length(p_tx_ids, 1), 0) - v_n;
  perform set_config('app.bank_reason', '', true); perform set_config('app.bank_actor', '', true);
  return jsonb_build_object('ok', true, 'updated_transactions', v_n, 'skipped', v_skip);
end $function$;

CREATE OR REPLACE FUNCTION public.bank_assignment_revert(p_history_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare h public.bank_assignment_history%rowtype; v_name text; v_new uuid; c public.bank_assignment_history%rowtype; v_ok int := 0; v_changed int := 0; t public.bank_transactions%rowtype; a public.bank_accounts%rowtype;
begin
  if not (public.bank_ledger_admin() and public.bank_write_ok()) then raise exception '権限がありません（閲覧専用の権限では、修正・紐付け・権限の操作はできません）'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由が必要です'; end if;
  select * into h from public.bank_assignment_history where id = p_history_id;
  if not found then raise exception '履歴が見つかりません'; end if;
  if h.action = 'revert' then raise exception '取り消しの履歴は取り消せません（もう一度紐付けてください）'; end if;
  if exists (select 1 from public.bank_assignment_history where reverts_id = p_history_id) then raise exception 'この履歴は、すでに取り消されています'; end if;
  select coalesce(u.name, u.id::text) into v_name from public.users u where u.id = auth.uid();
  perform set_config('app.bank_reason', btrim(p_reason), true); perform set_config('app.bank_actor', coalesce(v_name, 'user'), true);
  if h.kind = 'transaction' then
    select * into t from public.bank_transactions where id = h.transaction_id for update;
    if not public.bank_corp_ok(t.corporation_id) or not public.bank_corp_ok(nullif(h.before_values ->> 'corporation_id', '')::uuid) then raise exception '権限がありません（この明細の法人を見る権限がありません）'; end if;
    if t.confirm_status <> 'open' or t.is_adjusted then raise exception '確定済み・訂正済みの明細は、ここでは戻せません（訂正の手続きを使ってください）'; end if;
    if t.store_id is distinct from nullif(h.after_values ->> 'store_id', '')::uuid then raise exception 'この紐付けのあとに、明細の店舗が変わっているため、戻せません'; end if;
    update public.bank_transactions set store_id = nullif(h.before_values ->> 'store_id', '')::uuid, corporation_id = nullif(h.before_values ->> 'corporation_id', '')::uuid where id = t.id;
    insert into public.bank_assignment_history (kind, action, account_id, transaction_id, before_values, after_values, reverts_id, reason, actor_id, actor_label)
      values ('transaction', 'revert', h.account_id, h.transaction_id, h.after_values, h.before_values, h.id, btrim(p_reason), auth.uid(), coalesce(v_name, 'user'));
    v_ok := 1;
  else
    select * into a from public.bank_accounts where id = h.account_id for update;
    if not public.bank_corp_ok(a.corporation_id) or not public.bank_corp_ok(nullif(h.before_values ->> 'corporation_id', '')::uuid) then raise exception '権限がありません（この口座の法人を見る権限がありません）'; end if;
    if a.store_id is distinct from nullif(h.after_values ->> 'store_id', '')::uuid then raise exception 'この紐付けのあとに、口座の店舗が変わっているため、戻せません'; end if;
    insert into public.bank_assignment_history (kind, action, account_id, before_values, after_values, reverts_id, reason, actor_id, actor_label)
      values ('account', 'revert', h.account_id, h.after_values, h.before_values, h.id, btrim(p_reason), auth.uid(), coalesce(v_name, 'user')) returning id into v_new;
    update public.bank_accounts set store_id = nullif(h.before_values ->> 'store_id', '')::uuid, corporation_id = nullif(h.before_values ->> 'corporation_id', '')::uuid,
           store_status = coalesce(h.before_values ->> 'store_status', 'unassigned'), updated_at = now() where id = h.account_id;
    for c in select * from public.bank_assignment_history where parent_id = h.id and action <> 'revert' loop
      select * into t from public.bank_transactions where id = c.transaction_id for update;
      if t.confirm_status = 'open' and not t.is_adjusted and t.store_id is not distinct from nullif(c.after_values ->> 'store_id', '')::uuid then
        update public.bank_transactions set store_id = nullif(c.before_values ->> 'store_id', '')::uuid, corporation_id = nullif(c.before_values ->> 'corporation_id', '')::uuid where id = t.id;
        insert into public.bank_assignment_history (kind, action, account_id, transaction_id, parent_id, before_values, after_values, reverts_id, reason, actor_id, actor_label)
          values ('transaction', 'revert', c.account_id, c.transaction_id, v_new, c.after_values, c.before_values, c.id, btrim(p_reason), auth.uid(), coalesce(v_name, 'user'));
        v_ok := v_ok + 1;
      else v_changed := v_changed + 1; end if;
    end loop;
  end if;
  perform set_config('app.bank_reason', '', true); perform set_config('app.bank_actor', '', true);
  return jsonb_build_object('ok', true, 'reverted', v_ok, 'not_reverted_because_changed_later', v_changed);
end $function$;

CREATE OR REPLACE FUNCTION public.store_corporation_change(p_store uuid, p_corp uuid, p_from date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_cur public.store_corporation_periods%rowtype;
begin
  if not (public.bank_global_admin() and public.bank_write_ok()) then raise exception '権限がありません（運営法人の変更は、全法人の管理者だけ）'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由が必要です'; end if;
  select * into v_cur from public.store_corporation_periods where store_id = p_store and valid_to is null order by valid_from desc limit 1;
  if found then
    if p_from <= v_cur.valid_from then raise exception '新しい開始日は、いまの期間の開始日（%）より後にしてください', v_cur.valid_from; end if;
    update public.store_corporation_periods set valid_to = p_from - 1 where id = v_cur.id;
  end if;
  insert into public.store_corporation_periods (store_id, corporation_id, valid_from, note, created_by) values (p_store, p_corp, p_from, btrim(p_reason), auth.uid());
  return jsonb_build_object('ok', true, 'store_id', p_store, 'corporation_id', p_corp, 'valid_from', p_from, 'past_bank_rows_changed', 0);
end $function$;

CREATE OR REPLACE FUNCTION public.bank_ledger_global_set(p_user uuid, p_on boolean, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not (public.bank_global_admin() and public.bank_write_ok()) then raise exception '権限がありません（全法人の閲覧権限の付与は、全法人の管理者だけ）'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由が必要です'; end if;
  if p_on then
    if not exists (select 1 from public.users u where u.id = p_user and u.is_active and u.role = 'HQ') then raise exception '付与できるのは、有効な本部（HQ）の人だけです（社長・マスターは付与なしで全法人）'; end if;
    insert into public.bank_ledger_global_users (user_id, granted_by, note) values (p_user, auth.uid(), btrim(p_reason)) on conflict do nothing;
  else
    update public.bank_ledger_global_users set revoked_at = now(), revoked_by = auth.uid(), note = coalesce(note, '') || ' / 取り消し: ' || btrim(p_reason) where user_id = p_user and revoked_at is null;
  end if;
  return jsonb_build_object('ok', true, 'user_id', p_user, 'on', p_on);
end $function$;

CREATE OR REPLACE FUNCTION public.bank_diff_decide(p_item_ids uuid[], p_decision text, p_reason text, p_kind text DEFAULT NULL::text, p_expect_count integer DEFAULT NULL::integer, p_expect_total numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_batch uuid; v_it public.bank_diff_items%rowtype; v_name text; v_n int := 0; v_tx uuid; v_ids uuid[]; v_cnt int; v_total numeric; v_mode text;
begin
  if not (public.bank_global_admin() and public.bank_write_ok()) then raise exception '権限がありません'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由が必要です'; end if;
  if p_decision not in ('approved', 'held', 'rejected', 'corrected') then raise exception '決定は approved / held / rejected / corrected のどれかです'; end if;
  select array_agg(distinct x) into v_ids from unnest(coalesce(p_item_ids, '{}')) x;
  if v_ids is null or array_length(v_ids, 1) < 1 then raise exception '対象が空です'; end if;
  v_cnt := array_length(v_ids, 1); v_mode := case when v_cnt = 1 then 'single' else 'bulk' end;
  if (select count(*) from public.bank_diff_items where id = any (v_ids)) <> v_cnt then raise exception '存在しない差異が含まれています'; end if;
  if p_kind is not null and exists (select 1 from public.bank_diff_items where id = any (v_ids) and kind <> p_kind) then raise exception '指定した種類（%）以外の差異が含まれています', p_kind; end if;
  select coalesce(sum(coalesce(amount, 0)), 0) into v_total from public.bank_diff_items where id = any (v_ids);
  -- 個別確認の対象（高額・マイナス・ゼロ）は、一括にできない
  if v_mode = 'bulk' and p_decision in ('approved', 'rejected')
     and exists (select 1 from public.bank_diff_items where id = any (v_ids) and detail ->> 'review_class' = 'individual') then
    raise exception '個別確認が必要な行（高額・マイナス・ゼロの調整）が含まれています。1 件ずつ承認・却下してください';
  end if;
  -- 一括の承認・却下は、確認した件数と合計が実際と一致していること
  if v_mode = 'bulk' and p_decision in ('approved', 'rejected') then
    if p_expect_count is null or p_expect_total is null then raise exception '一括の承認・却下には、確認した件数と合計（符号つき）が必要です'; end if;
    if p_expect_count <> v_cnt or p_expect_total <> v_total then raise exception '確認した件数・合計（% 件・%）が、実際の対象（% 件・%）と一致しません', p_expect_count, p_expect_total, v_cnt, v_total; end if;
  elsif p_expect_count is not null and p_expect_count <> v_cnt or p_expect_total is not null and p_expect_total <> v_total then
    raise exception '確認した件数・合計が、実際の対象と一致しません';
  end if;
  select coalesce(u.name, u.id::text) into v_name from public.users u where u.id = auth.uid();
  insert into public.bank_decision_batches (mode, decision, reason, actor_id, actor_label, item_ids, item_count, total_amount, expected_count, expected_total)
    values (v_mode, p_decision, btrim(p_reason), auth.uid(), coalesce(v_name, 'user'), v_ids, v_cnt, v_total, p_expect_count, p_expect_total) returning id into v_batch;
  for v_it in select * from public.bank_diff_items where id = any (v_ids) order by id for update loop
    if p_decision = 'corrected' then
      foreach v_tx in array v_it.transaction_ids loop
        if not exists (select 1 from public.bank_transactions t where t.id = v_tx and (t.is_adjusted or exists (select 1 from public.bank_transaction_events e where e.transaction_id = v_tx and e.event_kind = 'correct'))) then
          raise exception '訂正の記録がありません（先に bank_tx_correct で訂正してください）';
        end if;
      end loop;
    end if;
    if p_decision = 'approved' and v_it.kind = 'paired_held' then      -- 保留の解除は、1 対 1 の対応が確かめられたときだけ
      foreach v_tx in array v_it.transaction_ids loop
        if not exists (
          select 1 from public.bank_transactions t
            join public.bank_legacy_links k on k.transaction_id = t.id and k.kind = 'paired' and k.confidence in ('auto', 'approved')
            join public.bank_legacy_rows r on r.content_hash || '#' || r.ordinal = k.legacy_key
           where t.id = v_tx and r.store_id = t.store_id and r.txn_date = t.txn_date and r.amount = t.deposit_amount
             and (select count(*) from public.bank_legacy_links k2 where k2.transaction_id = t.id) = 1
             and (select count(*) from public.bank_legacy_links k3 where k3.legacy_key = k.legacy_key) = 1)
        then raise exception '旧の行との 1 対 1 の対応（同じ店舗ID・日付・金額）が確かめられないため、保留を解けません';
        end if;
      end loop;
    end if;
    if p_decision = 'approved' and v_it.kind in ('bank_only', 'paired_held') then      -- 銀行側の保留（旧に無い／旧と対応済み）→ 照合済みへ
      perform set_config('app.bank_reason', btrim(p_reason), true); perform set_config('app.bank_actor', coalesce(v_name, 'user'), true);
      update public.bank_transactions set match_status = 'verified', hold_reason = null
       where id = any (v_it.transaction_ids) and match_status = 'held';
      perform set_config('app.bank_reason', '', true); perform set_config('app.bank_actor', '', true);
    elsif p_decision = 'approved' and v_it.kind = 'ambiguous_pair' then
      update public.bank_legacy_links set confidence = 'approved' where legacy_key = any (v_it.legacy_keys);
    elsif p_decision = 'rejected' then
      foreach v_tx in array v_it.transaction_ids loop
        perform public.bank_tx_correct(v_tx, '{"counts_as_sales_deposit": false}'::jsonb, p_reason);
      end loop;
      -- 旧のみ・調整の行（移行済み）も同様に集計から外す（数字が変わる決定）
      for v_tx in select k.transaction_id from public.bank_legacy_links k where k.legacy_key = any (v_it.legacy_keys) and k.transaction_id is not null and k.kind in ('migrated', 'adjustment') loop
        perform public.bank_tx_correct(v_tx, '{"counts_as_sales_deposit": false}'::jsonb, p_reason);
      end loop;
    end if;
    insert into public.bank_diff_decisions (batch_id, item_id, from_status, to_status) values (v_batch, v_it.id, v_it.status, p_decision);
    update public.bank_diff_items set status = p_decision, decided_at = now(), decided_by = auth.uid(), decided_reason = btrim(p_reason) where id = v_it.id;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('decision_batch', v_batch, 'mode', v_mode, 'items', v_n, 'total', v_total);
end $function$;

drop policy if exists bank_deposit_notes_write on public.bank_deposit_notes;
create policy bank_deposit_notes_write on public.bank_deposit_notes for all to authenticated
  using (public.bank_ledger_admin() and public.bank_store_visible(store_id) and public.bank_write_ok())
  with check (public.bank_ledger_admin() and public.bank_store_visible(store_id) and public.bank_write_ok());
