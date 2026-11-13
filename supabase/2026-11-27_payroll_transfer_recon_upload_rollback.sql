-- =============================================================
-- 2026-11-27_payroll_transfer_recon_upload.sql の戻し（下書き・★本番未適用）
--   1. 作り直した 3 つの関数（照合・銀行の取り込みの入口・画面用の状況）を、前の版に戻す
--      （下の定義は、2026-11-24・2026-11-25 の SQL から、行をそのまま写したもの。手では書きかえていない）。
--   2. 足した関数（人による取り込み・まとめての手動確認・その判定・画面用の元の中身）を外す。
--   3. 足した決まり（csv_upload）は、その値の行が 1 件も無いときだけ、前の決まりに戻す。足した列は、値が 1 件も無いときだけ消す（記録を消さない）。
--   4. 証憑の置き場: 読む・入れるの決まり（2 つ）を外す。バケットとファイルは **残す**（証憑を消さない。決まりが無いので、ログインした人は読めなくなる）。
--   注意: 「人が確認済みで、銀行の明細と結べている行」があるバッチは、戻したあとに照合をやり直すと、その行が「銀行の結果待ち」に戻る（記録は残る）。
--   既存の給与の表・スイッチの行には、もともと触れていないので、戻すものは無い。
-- =============================================================

-- ===== 1. 関数を前の版に戻す =====

-- 照合（2026-11-24 の版）
create or replace function public.payroll_recon_eval(p_batch_id uuid, p_actor_kind text default 'auto_bank')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_b payroll_transfer_batches%rowtype; v_t bank_bulk_transfers%rowtype; v_allowed jsonb;
  v_exact integer; v_full integer; v_near integer; v_exact_ids uuid[]; v_full_ids uuid[]; v_pick uuid; v_l record; v_cnt integer; v_did uuid; v_reason text;
  v_total integer; v_linked integer; v_manual integer; v_failed integer; v_notfinal integer; v_extra integer; v_counts jsonb;
begin
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id for update;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;

  select * into v_t from bank_bulk_transfers t where t.batch_id = v_b.id;
  if v_t.id is null then
    v_allowed := public.payroll_recon_setting() -> 'corps' -> (v_b.corporation_id::text) -> 'source_account_keys';
    if v_allowed is null or jsonb_typeof(v_allowed) <> 'array' or jsonb_array_length(v_allowed) = 0 then
      if exists (select 1 from bank_bulk_transfers t where t.batch_id is null and t.designated_date = v_b.scheduled_date) then
        perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'source_account_not_configured', p_actor_kind, null);
      end if;
      return jsonb_build_object('batch_id', v_b.id, 'linked', false, 'status', (select b.status from payroll_transfer_batches b where b.id = v_b.id));
    end if;
    select array_agg(c.id order by c.id) filter (where c.exact), array_agg(c.id order by c.id) filter (where c.exact and c.full_match), count(*)
      into v_exact_ids, v_full_ids, v_near
      from (
        select t.id,
               (t.total_count = v_b.expected_count and t.total_amount = v_b.expected_total) as exact,
               public.payroll_recon_lines_match(v_b.id, t.id) as full_match
          from bank_bulk_transfers t
         where t.batch_id is null and t.designated_date = v_b.scheduled_date and v_allowed ? t.source_account_key
           -- ほかのバッチ（まだ銀行取引と結んでいないもの）にぴったり合う取引は、このバッチの候補にしない。このバッチにもぴったり合うときは候補に残す
           and (public.payroll_recon_lines_match(v_b.id, t.id)
                or not exists (select 1 from payroll_transfer_batches b2
                                where b2.id <> v_b.id and b2.scheduled_date = t.designated_date
                                  and b2.expected_count = t.total_count and b2.expected_total = t.total_amount
                                  and not exists (select 1 from bank_bulk_transfers t2 where t2.batch_id = b2.id)
                                  and public.payroll_recon_lines_match(b2.id, t.id)))
      ) c;
    v_exact := coalesce(array_length(v_exact_ids, 1), 0);
    v_full := coalesce(array_length(v_full_ids, 1), 0);
    v_pick := case when v_exact = 1 then v_exact_ids[1] when v_exact > 1 and v_full = 1 then v_full_ids[1] else null end;
    if v_pick is not null then
      update bank_bulk_transfers t set batch_id = v_b.id, linked_at = now()
       where t.id = v_pick and t.batch_id is null
      returning * into v_t;
      perform public.payroll_recon_log(v_b.id, null, 'bank_linked', null, null, p_actor_kind, null, jsonb_build_object('bank_transfer_id', v_t.id, 'candidates', v_exact));
    elsif v_exact > 1 then
      perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'multiple_bank_candidates', p_actor_kind, jsonb_build_object('candidates', v_exact));
      return jsonb_build_object('batch_id', v_b.id, 'linked', false, 'status', 'pending_check');
    elsif v_near > 0 then
      perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'bank_total_mismatch', p_actor_kind, jsonb_build_object('same_day_transfers', v_near));
      return jsonb_build_object('batch_id', v_b.id, 'linked', false, 'status', 'pending_check');
    else
      return jsonb_build_object('batch_id', v_b.id, 'linked', false, 'status', v_b.status);
    end if;
  end if;

  if not exists (select 1 from bank_bulk_transfer_details d where d.transfer_id = v_t.id) then
    perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'bank_details_missing', p_actor_kind, null);
    return jsonb_build_object('batch_id', v_b.id, 'linked', true, 'status', 'pending_check');
  end if;

  -- 予定者の行と明細を結ぶ（まだ結んでいない行だけ）
  for v_l in
    select l.id, l.acct_key, l.kana_norm, l.amount, l.line_status
      from payroll_transfer_batch_lines l where l.batch_id = v_b.id and l.bank_detail_id is null order by l.user_id
  loop
    v_reason := null; v_did := null;
    if (select count(*) from payroll_transfer_batch_lines l2 where l2.batch_id = v_b.id and l2.acct_key = v_l.acct_key) > 1 then
      v_reason := 'same_account_two_people';
    else
      select count(*), (array_agg(d.id))[1] into v_cnt, v_did
        from bank_bulk_transfer_details d
       where d.transfer_id = v_t.id and d.acct_key = v_l.acct_key and d.kana_norm = v_l.kana_norm and d.amount = v_l.amount
         and not exists (select 1 from payroll_transfer_batch_lines lx where lx.bank_detail_id = d.id);
      if v_cnt = 1 then
        v_reason := null;
      elsif v_cnt > 1 then
        v_reason := 'multiple_candidates';
      elsif exists (select 1 from bank_bulk_transfer_details d where d.transfer_id = v_t.id and d.acct_key = v_l.acct_key and d.kana_norm = v_l.kana_norm) then
        v_reason := 'amount_mismatch';
      elsif exists (select 1 from bank_bulk_transfer_details d where d.transfer_id = v_t.id and d.acct_key = v_l.acct_key) then
        v_reason := 'kana_mismatch';
      elsif exists (select 1 from bank_bulk_transfer_details d where d.transfer_id = v_t.id and d.kana_norm = v_l.kana_norm and d.amount = v_l.amount and d.acct_key is not null) then
        v_reason := 'account_mismatch';
      elsif exists (select 1 from bank_bulk_transfer_details d where d.transfer_id = v_t.id and d.acct_key is null) then
        v_reason := 'bank_account_unreadable';
      else
        v_reason := 'not_found_in_bank';
      end if;
    end if;
    if v_reason is null then
      update payroll_transfer_batch_lines l set bank_detail_id = v_did, updated_at = now() where l.id = v_l.id;
      perform public.payroll_recon_log(v_b.id, v_l.id, 'line_linked', null, null, p_actor_kind, null, null);
    elsif v_l.line_status <> 'manual_confirmed' then
      perform public.payroll_recon_set_line(v_l.id, 'pending_check', v_reason, p_actor_kind);
    end if;
  end loop;

  -- 結べた行の状態を、銀行の結果に合わせる
  for v_l in
    select l.id, l.line_status, d.result
      from payroll_transfer_batch_lines l join bank_bulk_transfer_details d on d.id = l.bank_detail_id
     where l.batch_id = v_b.id
  loop
    if v_l.result = 'failed' then
      perform public.payroll_recon_set_line(v_l.id, 'failed', 'bank_failed', p_actor_kind);
    elsif v_l.result = 'returned' then
      perform public.payroll_recon_set_line(v_l.id, 'returned', 'bank_returned', p_actor_kind);
    elsif v_l.result = 'success' then
      if v_l.line_status <> 'completed' then
        perform public.payroll_recon_set_line(v_l.id, 'bank_matched', null, p_actor_kind);
      end if;
    else
      perform public.payroll_recon_set_line(v_l.id, 'bank_matched', 'bank_result_' || v_l.result, p_actor_kind);
    end if;
  end loop;

  select count(*),
         count(*) filter (where l.bank_detail_id is not null),
         count(*) filter (where l.bank_detail_id is null and l.line_status = 'manual_confirmed'),
         count(*) filter (where d.result in ('failed', 'returned')),
         count(*) filter (where l.bank_detail_id is not null and d.result not in ('success', 'failed', 'returned'))
    into v_total, v_linked, v_manual, v_failed, v_notfinal
    from payroll_transfer_batch_lines l left join bank_bulk_transfer_details d on d.id = l.bank_detail_id
   where l.batch_id = v_b.id;
  select count(*) into v_extra from bank_bulk_transfer_details d
   where d.transfer_id = v_t.id and not exists (select 1 from payroll_transfer_batch_lines l where l.bank_detail_id = d.id);
  v_counts := jsonb_build_object('people', v_total, 'linked', v_linked, 'manual', v_manual, 'failed', v_failed, 'not_final', v_notfinal, 'bank_extra', v_extra);

  if v_failed > 0 then
    perform public.payroll_recon_set_batch(v_b.id, 'failed', 'bank_failed_or_returned', p_actor_kind, v_counts);
  elsif v_linked + v_manual < v_total then
    perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'lines_not_matched', p_actor_kind, v_counts);
  elsif v_extra > v_manual then
    perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'bank_has_extra_details', p_actor_kind, v_counts);
  elsif v_notfinal > 0 or v_t.bank_status <> 'done' then
    perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'bank_result_not_final', p_actor_kind, v_counts);
  elsif v_manual > 0 then
    perform public.payroll_recon_complete(v_b.id, 'manual', p_actor_kind, null);
  else
    update payroll_transfer_batches b set bank_matched_at = coalesce(b.bank_matched_at, now()), updated_at = now() where b.id = v_b.id;
    if public.payroll_recon_flag('auto_complete') then
      perform public.payroll_recon_complete(v_b.id, 'auto', p_actor_kind, null);
    elsif (select b.status from payroll_transfer_batches b where b.id = v_b.id) <> 'completed' then
      perform public.payroll_recon_set_batch(v_b.id, 'bank_matched', null, p_actor_kind, v_counts);
    end if;
  end if;

  return jsonb_build_object('batch_id', v_b.id, 'linked', true, 'status', (select b.status from payroll_transfer_batches b where b.id = v_b.id), 'counts', v_counts);
end $$;
revoke all on function public.payroll_recon_eval(uuid, text) from public, anon, authenticated;

-- 銀行の取り込みの入口（2026-11-25 の版）
create or replace function public.bank_bulk_transfer_ingest(p_transfer jsonb, p_details jsonb default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_bank text; v_key text; v_ref text; v_date date; v_cnt integer; v_total numeric; v_status text; v_raw text;
  v_t bank_bulk_transfers%rowtype; v_old bank_bulk_transfer_details%rowtype; v_d record;
  v_new boolean := false; v_changed integer := 0; v_dn integer; v_dsum numeric; v_dlines integer; v_akey text; v_kana text;
  v_batch uuid; v_evals jsonb := '[]'::jsonb; v_line uuid;
  v_service boolean := public.payroll_recon_is_service(); v_src text; v_exec date; v_fee numeric; v_grand numeric; v_okc integer; v_errc integer;
  v_seen timestamptz; v_sha text; v_fmt text; v_basis text; v_nsucc integer := 0; v_nfinal integer := 0;
begin
  if not public.payroll_recon_can() then raise exception '権限がありません'; end if;
  if v_service and not public.payroll_recon_flag('bank_read_enabled') then
    raise exception '銀行の読み取りのスイッチ（bank_read_enabled）が OFF です。取り込みません';
  end if;
  if p_transfer is null or jsonb_typeof(p_transfer) <> 'object' then raise exception '総合振込の情報がありません'; end if;
  v_bank := coalesce(nullif(btrim(p_transfer ->> 'bank'), ''), 'paypay');
  v_key := nullif(btrim(p_transfer ->> 'source_account_key'), '');
  v_ref := nullif(btrim(p_transfer ->> 'bank_ref'), '');
  v_date := (p_transfer ->> 'designated_date')::date;
  v_cnt := (p_transfer ->> 'total_count')::integer;
  v_total := (p_transfer ->> 'total_amount')::numeric;
  v_raw := p_transfer ->> 'bank_status_raw';
  v_status := coalesce(nullif(btrim(p_transfer ->> 'bank_status'), ''), 'unknown');
  if v_key is null or v_ref is null or v_date is null or v_cnt is null or v_total is null then
    raise exception '総合振込の情報（出金口座の印・受付番号・振込指定日・件数・合計）が足りません';
  end if;
  if v_status not in ('accepted', 'processing', 'done', 'partial', 'failed', 'unknown') then raise exception '銀行の状態の値が不正です: %', v_status; end if;

  -- 足した項目
  v_src := nullif(btrim(p_transfer ->> 'detail_source'), '');
  v_exec := (p_transfer ->> 'executed_date')::date;
  v_fee := (p_transfer ->> 'fee_total')::numeric;
  v_grand := (p_transfer ->> 'grand_total')::numeric;
  v_okc := (p_transfer ->> 'ok_count')::integer;
  v_errc := (p_transfer ->> 'error_count')::integer;
  v_seen := (p_transfer ->> 'screen_seen_at')::timestamptz;
  v_sha := nullif(lower(btrim(p_transfer ->> 'csv_sha256')), '');
  v_fmt := nullif(btrim(p_transfer ->> 'csv_format'), '');
  if v_src is not null and v_src not in ('screen_rows', 'summary', 'none') then raise exception '明細の出どころ（detail_source）の値が不正です: %', v_src; end if;
  if v_service and v_src is null then raise exception 'ロボットからの取り込みには、明細の出どころ（detail_source）が必要です'; end if;
  if v_src = 'none' and p_details is not null then raise exception '明細の出どころが none なのに、明細が渡されています'; end if;
  if v_src in ('screen_rows', 'summary') and p_details is null then raise exception '明細の出どころが % なのに、明細がありません', v_src; end if;
  if v_fee is not null and v_grand is not null and v_total + v_fee <> v_grand then
    raise exception '「振込金額＋手数料」が「合計金額」と合いません。取り込みません';
  end if;
  if v_sha is not null and v_sha !~ '^[0-9a-f]{64}$' then raise exception 'CSV の指紋（SHA-256）の形が不正です'; end if;
  if v_fmt is not null and v_fmt not in ('zengin', 'list') then raise exception 'CSV の形式の値が不正です'; end if;
  v_basis := case v_src when 'screen_rows' then 'screen_row' when 'summary' then 'summary' else null end;

  if p_details is not null then
    if jsonb_typeof(p_details) <> 'array' then raise exception '明細は配列で渡してください'; end if;
    select count(*), coalesce(sum((d.value ->> 'amount')::numeric), 0), count(distinct (d.value ->> 'line_no')::integer)
      into v_dn, v_dsum, v_dlines from jsonb_array_elements(p_details) d;
    if v_dn <> v_cnt or v_dsum <> v_total or v_dlines <> v_dn then
      raise exception '明細の件数・合計が、総合振込の件数・合計と合いません（読み取りが途中で切れた可能性）。取り込みません';
    end if;
    if exists (select 1 from jsonb_array_elements(p_details) d
                where coalesce(nullif(btrim(d.value ->> 'result'), ''), 'unknown') not in ('success', 'failed', 'returned', 'accepted', 'processing', 'unknown')) then
      raise exception '明細の結果の値が不正です';
    end if;
    select count(*) filter (where coalesce(nullif(btrim(d.value ->> 'result'), ''), 'unknown') = 'success'),
           count(*) filter (where coalesce(nullif(btrim(d.value ->> 'result'), ''), 'unknown') in ('success', 'failed', 'returned'))
      into v_nsucc, v_nfinal from jsonb_array_elements(p_details) d;
    if v_src = 'summary' and v_nfinal > 0 then
      if not (public.payroll_recon_flag('summary_success_ok') and v_status = 'done' and v_nsucc = v_dn
              and v_okc is not distinct from v_cnt and v_errc is not distinct from 0) then
        raise exception '画面の行で確かめていない明細に、成功・失敗の結果は記録できません（CSV の件数・合計が合っただけでは、完了にしません）';
      end if;
    end if;
    if v_src = 'screen_rows' and v_okc is not null and v_okc <> v_nsucc then
      raise exception '画面の「正常件数」と、行ごとに読んだ「成功」の数が合いません。取り込みません';
    end if;
  end if;

  perform set_config('payroll.recon_ok', '1', true);
  perform pg_advisory_xact_lock(hashtext('bank_bulk_transfer:' || v_bank || ':' || v_key || ':' || v_ref));
  select * into v_t from bank_bulk_transfers t where t.bank = v_bank and t.source_account_key = v_key and t.bank_ref = v_ref for update;
  if v_t.id is null then
    insert into bank_bulk_transfers(bank, source_account_key, bank_ref, designated_date, total_count, total_amount, fee_total, bank_status_raw, bank_status, login_profile,
                                    executed_date, grand_total, ok_count, error_count, memo, screen_seen_at, detail_source, result_verified_at, csv_sha256, csv_format)
    values (v_bank, v_key, v_ref, v_date, v_cnt, v_total, v_fee, v_raw, v_status, p_transfer ->> 'login_profile',
            v_exec, v_grand, v_okc, v_errc, nullif(btrim(p_transfer ->> 'memo'), ''), v_seen, v_src, case when v_src = 'screen_rows' then now() end, v_sha, v_fmt)
    returning * into v_t;
    v_new := true;
    perform public.payroll_recon_log(null, null, 'bank_imported', null, v_status, 'auto_bank', null,
                                     jsonb_build_object('bank_transfer_id', v_t.id, 'designated_date', v_date, 'count', v_cnt, 'detail_source', v_src));
  else
    if v_t.designated_date <> v_date or v_t.total_count <> v_cnt or v_t.total_amount <> v_total then
      raise exception '同じ受付番号なのに、振込指定日・件数・合計が前回と違います。取り込みません';
    end if;
    if v_t.bank_status is distinct from v_status then
      perform public.payroll_recon_log(v_t.batch_id, null, 'bank_status_changed', v_t.bank_status, v_status, 'auto_bank', null, jsonb_build_object('bank_transfer_id', v_t.id));
    end if;
    update bank_bulk_transfers t
       set bank_status = v_status, bank_status_raw = coalesce(v_raw, t.bank_status_raw), last_seen_at = now(),
           fee_total = coalesce(v_fee, t.fee_total), executed_date = coalesce(v_exec, t.executed_date), grand_total = coalesce(v_grand, t.grand_total),
           ok_count = coalesce(v_okc, t.ok_count), error_count = coalesce(v_errc, t.error_count), memo = coalesce(nullif(btrim(p_transfer ->> 'memo'), ''), t.memo),
           screen_seen_at = coalesce(v_seen, t.screen_seen_at),
           -- 画面の行で確かめたことがあれば、あとから summary・none が来ても「screen_rows」のまま
           detail_source = case when t.detail_source = 'screen_rows' then 'screen_rows' when v_src in ('screen_rows', 'summary') then v_src else coalesce(t.detail_source, v_src) end,
           result_verified_at = case when v_src = 'screen_rows' then now() else t.result_verified_at end,
           csv_sha256 = coalesce(v_sha, t.csv_sha256), csv_format = coalesce(v_fmt, t.csv_format)
     where t.id = v_t.id
    returning * into v_t;
  end if;

  if p_details is not null then
    for v_d in
      select (d.value ->> 'line_no')::integer as line_no, d.value ->> 'bank_code' as bank_code, d.value ->> 'branch_code' as branch_code,
             d.value ->> 'account_type' as account_type, d.value ->> 'account_number' as account_number, d.value ->> 'holder_kana' as holder_kana,
             (d.value ->> 'amount')::numeric as amount, coalesce(nullif(btrim(d.value ->> 'result'), ''), 'unknown') as result, d.value ->> 'result_raw' as result_raw,
             nullif(btrim(d.value ->> 'bank_name'), '') as bank_name, nullif(btrim(d.value ->> 'branch_name'), '') as branch_name
        from jsonb_array_elements(p_details) d
    loop
      v_akey := public.payroll_recon_acct_key(v_d.bank_code, v_d.branch_code, v_d.account_type, v_d.account_number);
      v_kana := public.payroll_recon_kana_norm(v_d.holder_kana);
      select * into v_old from bank_bulk_transfer_details x where x.transfer_id = v_t.id and x.line_no = v_d.line_no;
      if v_old.id is null then
        insert into bank_bulk_transfer_details(transfer_id, line_no, bank_code, branch_code, account_type, account_number, holder_kana, acct_key, kana_norm, amount, result_raw, result,
                                               bank_name, branch_name, result_basis, result_checked_at)
        values (v_t.id, v_d.line_no, v_d.bank_code, v_d.branch_code, v_d.account_type, v_d.account_number, v_d.holder_kana, v_akey, v_kana, v_d.amount, v_d.result_raw, v_d.result,
                v_d.bank_name, v_d.branch_name, v_basis, case when v_basis = 'screen_row' then now() end);
      else
        if v_old.acct_key is distinct from v_akey or v_old.kana_norm is distinct from v_kana or v_old.amount <> v_d.amount then
          raise exception '同じ受付番号・同じ行番号なのに、振込先や金額が前回と違います。取り込みません';
        end if;
        if v_basis = 'summary' and v_old.result_basis = 'screen_row' then
          -- 画面の行で確かめた結果は、一覧と件数だけの取り込みでは変えない
          update bank_bulk_transfer_details x set last_seen_at = now() where x.id = v_old.id;
        elsif v_old.result is distinct from v_d.result then
          select l.id into v_line from payroll_transfer_batch_lines l where l.bank_detail_id = v_old.id;
          update bank_bulk_transfer_details x
             set result = v_d.result, result_raw = coalesce(v_d.result_raw, x.result_raw), last_seen_at = now(),
                 bank_name = coalesce(v_d.bank_name, x.bank_name), branch_name = coalesce(v_d.branch_name, x.branch_name),
                 result_basis = v_basis, result_checked_at = case when v_basis = 'screen_row' then now() else x.result_checked_at end   -- 結果が変わったので、根拠も今回のものにする
           where x.id = v_old.id;
          perform public.payroll_recon_log(v_t.batch_id, v_line, 'bank_result_changed', v_old.result, v_d.result, 'auto_bank', null,
                                           jsonb_build_object('bank_transfer_id', v_t.id, 'line_no', v_d.line_no, 'result_basis', v_basis));
          v_changed := v_changed + 1;
        else
          update bank_bulk_transfer_details x
             set last_seen_at = now(), bank_name = coalesce(v_d.bank_name, x.bank_name), branch_name = coalesce(v_d.branch_name, x.branch_name),
                 result_basis = coalesce(v_basis, x.result_basis), result_checked_at = case when v_basis = 'screen_row' then now() else x.result_checked_at end
           where x.id = v_old.id;
        end if;
      end if;
    end loop;
  end if;

  -- 照合: 結び済みならそのバッチ、まだなら、振込指定日が同じで銀行取引と結んでいないバッチを順に確かめる（元のまま）
  if v_t.batch_id is not null then
    v_evals := v_evals || jsonb_build_array(public.payroll_recon_eval(v_t.batch_id, 'auto_bank'));
  else
    for v_batch in
      select b.id from payroll_transfer_batches b
       where b.scheduled_date = v_date and not exists (select 1 from bank_bulk_transfers t2 where t2.batch_id = b.id)
       order by public.payroll_recon_lines_match(b.id, v_t.id) desc, b.year_month, b.batch_seq   -- 明細がぴったり合うバッチを先に
    loop
      v_evals := v_evals || jsonb_build_array(public.payroll_recon_eval(v_batch, 'auto_bank'));
    end loop;
  end if;
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'bank_transfer_id', v_t.id, 'new', v_new, 'results_changed', v_changed, 'detail_source', v_t.detail_source, 'batches', v_evals);
end $$;
revoke all on function public.bank_bulk_transfer_ingest(jsonb, jsonb) from public, anon;
grant execute on function public.bank_bulk_transfer_ingest(jsonb, jsonb) to authenticated, service_role;

-- 画面用の関数（2026-11-24 の版）
create or replace function public.payroll_transfer_recon_status(p_year_month text, p_corp_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.payroll_pay_can() then raise exception '権限がありません'; end if;
  return jsonb_build_object(
    'ok', true, 'year_month', p_year_month,
    'switches', jsonb_build_object('mf_total_enabled', public.payroll_recon_flag('mf_total_enabled'), 'bank_read_enabled', public.payroll_recon_flag('bank_read_enabled'),
                                   'auto_complete', public.payroll_recon_flag('auto_complete'), 'slack_enabled', public.payroll_recon_flag('slack_enabled')),
    'batch_count', (select count(*) from payroll_transfer_batches b where b.year_month = p_year_month and (p_corp_id is null or b.corporation_id = p_corp_id)),
    'batches', (
      select coalesce(jsonb_agg(x.j order by x.corp_name, x.batch_seq), '[]'::jsonb)
        from (
          select coalesce((select c.name from corporations c where c.id = b.corporation_id), '') as corp_name, b.batch_seq,
                 jsonb_build_object(
                   'batch_id', b.id, 'corporation_id', b.corporation_id, 'corp_name', (select c.name from corporations c where c.id = b.corporation_id),
                   'batch_seq', b.batch_seq, 'batch_kind', b.batch_kind, 'batch_kind_label', public.payroll_transfer_kind_label(b.batch_kind), 'kind_reason', b.kind_reason,
                   'scheduled_date', b.scheduled_date, 'status', b.status, 'status_label', public.payroll_transfer_status_label(b.status, b.completed_kind),
                   'status_reason', b.status_reason, 'expected_count', b.expected_count, 'expected_total', b.expected_total,
                   'mf_matched_at', b.mf_matched_at, 'bank_matched_at', b.bank_matched_at, 'completed_at', b.completed_at, 'completed_kind', b.completed_kind,
                   'failed_at', b.failed_at, 'frozen_at', b.frozen_at,
                   'mf', (select coalesce(jsonb_agg(jsonb_build_object('result', m.result, 'transaction_date', m.transaction_date, 'deposit_account', m.deposit_account, 'checked_at', m.checked_at) order by m.checked_at), '[]'::jsonb)
                            from payroll_mf_total_matches m where m.batch_id = b.id),
                   'bank', (select jsonb_build_object('bank_transfer_id', t.id, 'bank', t.bank, 'designated_date', t.designated_date, 'total_count', t.total_count,
                                                      'bank_status', t.bank_status, 'bank_status_raw', t.bank_status_raw, 'linked_at', t.linked_at, 'last_seen_at', t.last_seen_at)
                              from bank_bulk_transfers t where t.batch_id = b.id),
                   'line_counts', (select coalesce(jsonb_object_agg(s.line_status, s.n), '{}'::jsonb)
                                     from (select l.line_status, count(*) as n from payroll_transfer_batch_lines l where l.batch_id = b.id group by l.line_status) s),
                   'lines', (select coalesce(jsonb_agg(jsonb_build_object('line_id', l.id, 'user_id', l.user_id, 'name', (select u.name from users u where u.id = l.user_id), 'line_status', l.line_status,
                                                                         'reason', l.status_reason, 'amount', l.amount, 'bank_name', l.account ->> 'bank_name',
                                                                         'linked', l.bank_detail_id is not null, 'manual', l.manual_confirmation_id is not null,
                                                                         'retry_of_line_id', l.retry_of_line_id, 'note', l.line_note,
                                                                         -- この行（失敗・組戻し）に対して作られた再振込（あれば、そのバッチの連番と行の状態）
                                                                         'retried_by', (select jsonb_build_object('batch_id', rb.id, 'batch_seq', rb.batch_seq, 'line_status', r.line_status,
                                                                                                                   'batch_status_label', public.payroll_transfer_status_label(rb.status, rb.completed_kind))
                                                                                          from payroll_transfer_batch_lines r join payroll_transfer_batches rb on rb.id = r.batch_id
                                                                                         where r.retry_of_line_id = l.id))
                                                      order by (l.line_status in ('completed', 'bank_matched')), l.user_id), '[]'::jsonb)
                               from payroll_transfer_batch_lines l where l.batch_id = b.id),
                   'manual', (select coalesce(jsonb_agg(jsonb_build_object('id', mc.id, 'user_id', mc.user_id, 'action', mc.action, 'basis', mc.basis, 'reason', mc.reason,
                                                                          'confirmed_by', mc.confirmed_by, 'confirmed_by_name', (select u.name from users u where u.id = mc.confirmed_by),
                                                                          'confirmed_at', mc.confirmed_at) order by mc.id), '[]'::jsonb)
                                from payroll_transfer_manual_confirmations mc where mc.batch_id = b.id),
                   'evidence', (select coalesce(jsonb_agg(jsonb_build_object('evidence_id', e.id, 'kind', e.kind, 'wanted_kind', e.wanted_kind, 'storage_bucket', e.storage_bucket,
                                                                            'storage_path', e.storage_path, 'size_bytes', e.size_bytes, 'fetched_at', e.fetched_at, 'source', e.source,
                                                                            'fetched_by', e.fetched_by, 'unavailable_reason', e.unavailable_reason) order by e.fetched_at), '[]'::jsonb)
                                  from payroll_transfer_evidence e where e.batch_id = b.id),
                   'events', (select coalesce(jsonb_agg(ev.j order by ev.id desc), '[]'::jsonb)
                                from (select v.id, jsonb_build_object('id', v.id, 'event', v.event, 'from', v.from_status, 'to', v.to_status, 'actor_kind', v.actor_kind,
                                                                      'actor_name', (select u.name from users u where u.id = v.actor_id), 'reason', v.reason, 'line_id', v.line_id, 'at', v.created_at) as j
                                        from payroll_transfer_recon_events v where v.batch_id = b.id order by v.id desc limit 100) ev)
                 ) as j
            from payroll_transfer_batches b
           where b.year_month = p_year_month and (p_corp_id is null or b.corporation_id = p_corp_id)
        ) x),
    -- どのバッチにも結び付けていない証憑（その月 × 法人）
    'evidence_other', (select coalesce(jsonb_agg(jsonb_build_object('evidence_id', e.id, 'corporation_id', e.corporation_id, 'kind', e.kind, 'wanted_kind', e.wanted_kind,
                                                                   'storage_bucket', e.storage_bucket, 'storage_path', e.storage_path, 'size_bytes', e.size_bytes, 'fetched_at', e.fetched_at,
                                                                   'source', e.source, 'fetched_by', e.fetched_by, 'unavailable_reason', e.unavailable_reason) order by e.fetched_at), '[]'::jsonb)
                         from payroll_transfer_evidence e
                        where e.year_month = p_year_month and (p_corp_id is null or e.corporation_id = p_corp_id) and e.batch_id is null)
  );
end $$;
revoke all on function public.payroll_transfer_recon_status(text, uuid) from public, anon;
grant execute on function public.payroll_transfer_recon_status(text, uuid) to authenticated;

-- ===== 2. 足した関数を外す =====
drop function if exists public.payroll_transfer_manual_confirm_matched(uuid, text, text, uuid);
drop function if exists public.payroll_transfer_bank_csv_register(jsonb, jsonb, text, text);
drop function if exists public.payroll_recon_manual_bulk_check(uuid, uuid);
drop function if exists public.payroll_transfer_recon_status_base(text, uuid);

-- ===== 3. 足した決まりと列（値が無いものだけ戻す・消す） =====
do $$
declare v_n bigint;
begin
  if to_regclass('public.bank_bulk_transfers') is not null then
    select count(*) into v_n from public.bank_bulk_transfers where detail_source = 'csv_upload';
    if v_n = 0 then
      alter table public.bank_bulk_transfers drop constraint if exists bank_bulk_transfers_detail_source_check;
      alter table public.bank_bulk_transfers add constraint bank_bulk_transfers_detail_source_check check (detail_source in ('screen_rows', 'summary', 'none'));
    else
      raise notice '人が登録した取引（csv_upload）が % 件あるため、明細の出どころの決まりは残しました', v_n;
    end if;
    select count(*) into v_n from public.bank_bulk_transfers where entered_by is not null or entered_at is not null;
    if v_n = 0 then
      alter table public.bank_bulk_transfers drop column if exists entered_by;
      alter table public.bank_bulk_transfers drop column if exists entered_at;
    else
      raise notice '入力した人の記録が % 件あるため、列 entered_by・entered_at は残しました', v_n;
    end if;
  end if;
  if to_regclass('public.bank_bulk_transfer_details') is not null then
    select count(*) into v_n from public.bank_bulk_transfer_details where result_basis = 'csv_upload';
    if v_n = 0 then
      alter table public.bank_bulk_transfer_details drop constraint if exists bank_bulk_transfer_details_result_basis_check;
      alter table public.bank_bulk_transfer_details add constraint bank_bulk_transfer_details_result_basis_check check (result_basis in ('screen_row', 'summary'));
    else
      raise notice '人が登録した明細（csv_upload）が % 件あるため、結果の根拠の決まりは残しました', v_n;
    end if;
  end if;
end $$;

-- ===== 4. 証憑の置き場: 決まりだけ外す（バケットとファイルは残す） =====
drop policy if exists payroll_transfer_evidence_insert on storage.objects;
drop policy if exists payroll_transfer_evidence_read on storage.objects;
