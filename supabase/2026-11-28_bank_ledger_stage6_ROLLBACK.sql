-- 段階6（2026-11-28_bank_ledger_stage6.sql）の取り消し。状態: 下書き（未適用）
-- 元の（段階1〜4 の）ポリシー・関数の定義に戻す。データは触らない。段階5の関数（bank_corp_ok など）は残す（段階5のロールバックで消える）。
-- 元の定義は、段階6を作った時点（2026-11-28）の本番の定義そのもの。

CREATE OR REPLACE FUNCTION public.bank_store_visible(p_store uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(auth.role(), '') = 'service_role'
      or public.bank_ledger_admin()
      or (p_store is not null and exists (
            select 1 from public.users u
             where u.id = auth.uid() and u.is_active
               and ((u.role = 'TEAM'   and p_store = any (coalesce(public.team_store_ids(u.team_id), '{}'::uuid[]) || coalesce(public.user_store_ids(u.id), '{}'::uuid[])))
                 or (u.role in ('TENCHO', 'SHAIN') and p_store = any (coalesce(public.user_store_ids(u.id), '{}'::uuid[]))))))
$function$;

CREATE OR REPLACE FUNCTION public.bank_deposit_daily(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date)
 RETURNS TABLE(store_id uuid, corporation_id uuid, deposit_date date, amount numeric, deposit_count integer, entries jsonb, legacy_pending_count integer, held_count integer, held_amount numeric, new_count integer, last_changed_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with e as (
    select t.*,
           coalesce(t.adj_txn_date, t.txn_date) as eff_date,
           coalesce(t.adj_deposit_amount, t.deposit_amount)
             - (case when t.tx_kind = 'adjustment' then coalesce(t.adj_withdrawal_amount, t.withdrawal_amount) else 0 end) as eff_dep,
           coalesce(t.adj_description, t.description) as eff_desc
      from public.bank_transactions t
     where t.counts_as_sales_deposit and t.store_id is not null and public.bank_store_visible(t.store_id)
  )
  select e.store_id,
         e.corporation_id,
         e.eff_date,
         coalesce(sum(e.eff_dep) filter (where e.match_status in ('legacy_pending', 'verified')), 0)::numeric,
         (count(*) filter (where e.match_status in ('legacy_pending', 'verified')))::int,
         coalesce(jsonb_agg(jsonb_build_object('a', e.eff_dep, 'm', left(e.eff_desc, 80))
                            order by e.txn_time nulls last, e.created_at, e.id)
                  filter (where e.match_status in ('legacy_pending', 'verified')), '[]'::jsonb),
         (count(*) filter (where e.match_status = 'legacy_pending'))::int,
         (count(*) filter (where e.match_status = 'held'))::int,
         coalesce(sum(e.eff_dep) filter (where e.match_status = 'held'), 0)::numeric,
         (count(*) filter (where e.match_status = 'new'))::int,
         max(e.updated_at)
    from e
   where (e.eff_dep > 0 or e.tx_kind = 'adjustment')
     and (p_from is null or e.eff_date >= p_from) and (p_to is null or e.eff_date <= p_to)
   group by e.store_id, e.corporation_id, e.eff_date
$function$;

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
  if not public.bank_ledger_admin() then raise exception '権限がありません'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '訂正の理由が必要です'; end if;
  if p_changes is null or jsonb_typeof(p_changes) <> 'object' or p_changes = '{}'::jsonb then raise exception '変更内容がありません'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not (k = any (v_allowed)) then raise exception '変更できない項目です（原本の事実は変えられません）: %', k; end if;
  end loop;
  select * into v_old from public.bank_transactions where id = p_id for update;
  if not found then raise exception '明細が見つかりません'; end if;
  if p_changes ? 'store_id' then
    select s.corporation_id into v_corp from public.stores s where s.id = nullif(p_changes ->> 'store_id', '')::uuid;
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

CREATE OR REPLACE FUNCTION public.bank_diff_decide(p_item_ids uuid[], p_decision text, p_reason text, p_kind text DEFAULT NULL::text, p_expect_count integer DEFAULT NULL::integer, p_expect_total numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_batch uuid; v_it public.bank_diff_items%rowtype; v_name text; v_n int := 0; v_tx uuid; v_ids uuid[]; v_cnt int; v_total numeric; v_mode text;
begin
  if not public.bank_ledger_admin() then raise exception '権限がありません'; end if;
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

CREATE OR REPLACE FUNCTION public.bank_diff_preview(p_kind text, p_review_class text DEFAULT NULL::text, p_status text DEFAULT 'open'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  if not (public.bank_ledger_admin() or coalesce(auth.role(), '') = 'service_role') then raise exception '権限がありません'; end if;
  select jsonb_build_object(
    'kind', p_kind, 'review_class', p_review_class, 'status', p_status,
    'count', count(*), 'total', coalesce(sum(coalesce(d.amount, 0)), 0),
    'positive_total', coalesce(sum(d.amount) filter (where d.amount > 0), 0), 'negative_total', coalesce(sum(d.amount) filter (where d.amount < 0), 0),
    'high', count(*) filter (where (d.detail ->> 'high')::boolean), 'negative', count(*) filter (where (d.detail ->> 'negative')::boolean), 'zero', count(*) filter (where (d.detail ->> 'zero')::boolean),
    'high_and_negative', count(*) filter (where (d.detail ->> 'high')::boolean and (d.detail ->> 'negative')::boolean),
    'individual_distinct', count(*) filter (where d.detail ->> 'review_class' = 'individual'),
    'ids', coalesce(jsonb_agg(d.id order by s.name, d.txn_date, d.id), '[]'::jsonb),
    'items', coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'store', s.name, 'date', d.txn_date, 'desc', d.description, 'amount', d.amount, 'review_class', d.detail ->> 'review_class') order by s.name, d.txn_date, d.id), '[]'::jsonb))
    into v
    from public.bank_diff_items d left join public.stores s on s.id = d.store_id
   where d.kind = p_kind and d.status = p_status and (p_review_class is null or d.detail ->> 'review_class' = p_review_class);
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.bank_legacy_report(p_batch uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb; v_rows int; v_notes int;
begin
  if not (public.bank_ledger_admin() or coalesce(auth.role(), '') = 'service_role') then raise exception '権限がありません'; end if;
  select row_count, notes_count into v_rows, v_notes from public.bank_legacy_batches where id = p_batch;
  with L as (select store_id, txn_date, count(*) c, sum(amount) a from public.bank_legacy_rows where batch_id = p_batch and store_id is not null group by 1, 2),
       D as (select store_id, deposit_date txn_date, deposit_count c, amount a, held_count hc from public.bank_deposit_daily()),
       C as (select coalesce(L.store_id, D.store_id) store_id, coalesce(L.txn_date, D.txn_date) txn_date,
                    coalesce(L.c, 0) lc, coalesce(L.a, 0) la, coalesce(D.c, 0) dc, coalesce(D.a, 0) da, coalesce(D.hc, 0) hc
               from L full join D on L.store_id = D.store_id and L.txn_date = D.txn_date)
  select jsonb_build_object(
    'legacy_rows', v_rows,
    'legacy_rows_saved', (select count(*) from public.bank_legacy_rows where batch_id = p_batch),
    'links_by_kind', coalesce((select jsonb_object_agg(kind, c) from (select k.kind, count(*) c from public.bank_legacy_rows r join public.bank_legacy_links k on k.legacy_key = r.content_hash || '#' || r.ordinal where r.batch_id = p_batch group by 1) q), '{}'::jsonb),
    'rows_without_link', (select count(*) from public.bank_legacy_rows r where r.batch_id = p_batch and not exists (select 1 from public.bank_legacy_links k where k.legacy_key = r.content_hash || '#' || r.ordinal)),
    'rows_unmigrated', (select count(*) from public.bank_legacy_rows r join public.bank_legacy_links k on k.legacy_key = r.content_hash || '#' || r.ordinal where r.batch_id = p_batch and k.kind in ('migrated', 'adjustment') and k.transaction_id is null),
    'store_dates_compared', (select count(*) from C),
    'store_dates_mismatch', (select count(*) from C where lc <> dc or la <> da),
    'mismatch_sample', coalesce((select jsonb_agg(jsonb_build_object('store_id', store_id, 'date', txn_date, 'legacy_count', lc, 'ledger_count', dc, 'legacy_amount', la, 'ledger_amount', da, 'held_in_ledger', hc) order by txn_date) from (select * from C where lc <> dc or la <> da order by txn_date limit 50) m), '[]'::jsonb),
    'legacy_total', (select coalesce(sum(la), 0) from C), 'ledger_total', (select coalesce(sum(da), 0) from C),
    'notes_legacy', v_notes,
    'notes_saved', (select count(*) from public.bank_legacy_notes where batch_id = p_batch),
    'notes_in_ledger_same', (select count(*) from public.bank_legacy_notes n join public.bank_deposit_notes d on d.store_id = n.store_id and d.note_date = n.note_date and d.note = n.note where n.batch_id = p_batch),
    'adjustments', (select jsonb_build_object(
        'rows', count(*),
        'numbers_preserved_rows', count(*) filter (where k.transaction_id is not null),          -- 移行で数字が維持された行（承認とは別）
        'legitimacy_pending', count(*) filter (where d.status in ('open', 'held')), 'legitimacy_approved', count(*) filter (where d.status = 'approved'), 'rejected', count(*) filter (where d.status = 'rejected'),
        'individual_distinct', count(*) filter (where d.detail ->> 'review_class' = 'individual'), 'high', count(*) filter (where (d.detail ->> 'high')::boolean),
        'negative', count(*) filter (where (d.detail ->> 'negative')::boolean), 'zero', count(*) filter (where (d.detail ->> 'zero')::boolean), 'high_and_negative', count(*) filter (where (d.detail ->> 'high')::boolean and (d.detail ->> 'negative')::boolean),
        'individual_pending', count(*) filter (where d.detail ->> 'review_class' = 'individual' and d.status in ('open', 'held')),
        'bulk_pending', count(*) filter (where d.detail ->> 'review_class' = 'bulk' and d.status in ('open', 'held')),
        'bulk_pending_total', coalesce(sum(d.amount) filter (where d.detail ->> 'review_class' = 'bulk' and d.status in ('open', 'held')), 0),
        'signed_total', coalesce(sum(d.amount), 0),
        'negative_rows_not_bank_withdrawals', (select count(*) from public.bank_transactions t where t.tx_kind = 'adjustment' and t.withdrawal_amount > 0 and t.bank_account_id is null))
       from public.bank_diff_items d left join public.bank_legacy_links k on k.legacy_key = d.legacy_keys[1] where d.batch_id = p_batch and d.kind = 'manual_adjustment'),
    'diff_items_by_kind_status', coalesce((select jsonb_object_agg(kind || '/' || status, c) from (select kind, status, count(*) c from public.bank_diff_items where batch_id = p_batch group by 1, 2) q), '{}'::jsonb),
    'csv_rows_fingerprint', public.bank_csv_rows_fingerprint()
  ) into v;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.bank_reconcile_report(p_days integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb; v_consec int := 0; r record;
begin
  if not (public.bank_ledger_admin() or coalesce(auth.role(), '') = 'service_role') then raise exception '権限がありません'; end if;
  for r in select distinct on (run_date) run_date, status from public.bank_reconcile_runs order by run_date desc, created_at desc loop
    exit when r.status <> 'ok'; v_consec := v_consec + 1;
  end loop;
  select jsonb_build_object(
    'days_observed', (select count(distinct run_date) from public.bank_reconcile_runs),
    'consecutive_ok_days', v_consec, 'criterion_days', p_days, 'criterion_met', v_consec >= p_days,
    'runs', coalesce((select jsonb_agg(jsonb_build_object('run_date', x.run_date, 'status', x.status, 'mismatches_open', x.mismatches_open, 'unexplained', x.mismatches_unexplained,
                'timing', x.mismatches_timing, 'new', x.mismatches_new, 'resolved', x.mismatches_resolved, 'legacy_rows', x.legacy_rows, 'paired_total', x.paired_total,
                'unpaired_legacy', x.unpaired_legacy, 'unpaired_bank', x.unpaired_bank, 'legacy_total', x.legacy_total, 'ledger_total', x.ledger_total) order by x.created_at desc)
                from (select * from public.bank_reconcile_runs order by created_at desc limit greatest(p_days * 2, 30)) x), '[]'::jsonb),
    'open_mismatches', coalesce((select jsonb_agg(jsonb_build_object('store_id', m.store_id, 'date', m.txn_date, 'cause', m.cause, 'is_timing', m.is_timing, 'days_open', m.days_open,
                'legacy_count', m.legacy_count, 'ledger_count', m.ledger_count, 'legacy_amount', m.legacy_amount, 'ledger_amount', m.ledger_amount) order by m.txn_date)
                from public.bank_reconcile_mismatches m where m.status = 'open'), '[]'::jsonb),
    'auto_resolved_total', (select count(*) from public.bank_reconcile_mismatches where status = 'auto_resolved')) into v;
  return v;
end $function$;

drop policy if exists bank_accounts_read on public.bank_accounts;
create policy bank_accounts_read on public.bank_accounts for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_transactions_read on public.bank_transactions;
create policy bank_transactions_read on public.bank_transactions for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_csv_originals_tbl_read on public.bank_csv_originals;
create policy bank_csv_originals_tbl_read on public.bank_csv_originals for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_import_files_read on public.bank_import_files;
create policy bank_import_files_read on public.bank_import_files for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_sync_state_read on public.bank_account_sync_state;
create policy bank_sync_state_read on public.bank_account_sync_state for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_tx_events_read on public.bank_transaction_events;
create policy bank_tx_events_read on public.bank_transaction_events for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_deposit_notes_write on public.bank_deposit_notes;
create policy bank_deposit_notes_write on public.bank_deposit_notes for all to authenticated using (public.bank_ledger_admin()) with check (public.bank_ledger_admin());
drop policy if exists bank_legacy_batches_read on public.bank_legacy_batches;
create policy bank_legacy_batches_read on public.bank_legacy_batches for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_legacy_rows_read on public.bank_legacy_rows;
create policy bank_legacy_rows_read on public.bank_legacy_rows for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_legacy_notes_read on public.bank_legacy_notes;
create policy bank_legacy_notes_read on public.bank_legacy_notes for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_legacy_links_read on public.bank_legacy_links;
create policy bank_legacy_links_read on public.bank_legacy_links for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_diff_items_read on public.bank_diff_items;
create policy bank_diff_items_read on public.bank_diff_items for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_decision_batches_read on public.bank_decision_batches;
create policy bank_decision_batches_read on public.bank_decision_batches for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_diff_decisions_read on public.bank_diff_decisions;
create policy bank_diff_decisions_read on public.bank_diff_decisions for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_reconcile_runs_read on public.bank_reconcile_runs;
create policy bank_reconcile_runs_read on public.bank_reconcile_runs for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_reconcile_mismatches_read on public.bank_reconcile_mismatches;
create policy bank_reconcile_mismatches_read on public.bank_reconcile_mismatches for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_csv_originals_read on storage.objects;
create policy bank_csv_originals_read on storage.objects for select using (bucket_id = 'bank-csv-originals' and public.bank_ledger_admin());
drop policy if exists bank_csv_originals_insert on storage.objects;
create policy bank_csv_originals_insert on storage.objects for insert with check (bucket_id = 'bank-csv-originals' and public.bank_ledger_admin());
drop function if exists public.bank_visible_account_texts();
drop function if exists public.bank_visible_account_ids();
