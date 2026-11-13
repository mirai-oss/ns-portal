-- =============================================================
-- 2026-11-25_payroll_transfer_recon_bankref.sql の戻し（下書き・★本番未適用）
--   1. 作り直した 3 つの関数（守りの引き金・追加/再振込/差額を固める・銀行の取り込みの入口）を、2026-11-24 の版に戻す
--      （下の定義は、2026-11-24_payroll_transfer_recon.sql から、行をそのまま写したもの。手では書きかえていない）。
--   2. 足した列は、**その列に値が 1 件も入っていないときだけ**消す（値があれば残す＝記録を消さない。残しても、戻した関数は読み書きしないので害はない）。
--   3. 振込先の出どころ（account_source）の決まりは、original の行が 1 件も無いときだけ、元の 2 つ（month・current）に戻す。
--   既存の給与の表・スイッチの行には、もともと触れていないので、戻すものは無い。
-- =============================================================

-- ===== 1. 関数を 2026-11-24 の版に戻す =====
-- 守りの引き金
create or replace function public.payroll_recon_guard()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('payroll.recon_ok', true), '') <> '1' then
    raise exception 'この表（%）は、振込照合の関数からしか変えられません', tg_table_name;
  end if;
  if tg_table_name = 'payroll_transfer_batches' and tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.year_month is distinct from old.year_month or new.corporation_id is distinct from old.corporation_id
       or new.batch_seq is distinct from old.batch_seq or new.batch_kind is distinct from old.batch_kind or new.kind_reason is distinct from old.kind_reason
       or new.expected_count is distinct from old.expected_count or new.expected_total is distinct from old.expected_total
       or new.lines_hash is distinct from old.lines_hash or new.frozen_at is distinct from old.frozen_at or new.frozen_by is distinct from old.frozen_by then
      raise exception '固めた振込バッチの内容（対象月・法人・種類・人数・合計）は変えられません';
    end if;
  end if;
  if tg_table_name = 'payroll_transfer_batch_lines' and tg_op = 'UPDATE' then
    if new.id is distinct from old.id or new.batch_id is distinct from old.batch_id or new.year_month is distinct from old.year_month
       or new.corporation_id is distinct from old.corporation_id or new.user_id is distinct from old.user_id or new.amount is distinct from old.amount
       or new.account is distinct from old.account or new.acct_key is distinct from old.acct_key or new.kana_norm is distinct from old.kana_norm
       or new.retry_of_line_id is distinct from old.retry_of_line_id or new.account_source is distinct from old.account_source then
      raise exception '固めた予定者の行（金額・振込先の控え・再振込の元の行）は変えられません';
    end if;
    if old.bank_detail_id is not null and new.bank_detail_id is distinct from old.bank_detail_id then
      raise exception '銀行の明細と結んだ行は、別の明細へ付け替えられません';
    end if;
  end if;
  if tg_table_name = 'bank_bulk_transfers' and tg_op = 'UPDATE' then
    if old.batch_id is not null and new.batch_id is distinct from old.batch_id then
      raise exception 'バッチと結んだ銀行取引は、別のバッチへ付け替えられません';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke all on function public.payroll_recon_guard() from public, anon, authenticated;

-- 追加・再振込・差額のバッチを固める
create or replace function public.payroll_transfer_batch_freeze_custom(p_year_month text, p_corp_id uuid, p_kind text, p_scheduled_date date, p_lines jsonb, p_reason text,
                                                                       p_account_source text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); v_src text; v_seq integer; v_batch uuid; v_cand jsonb; v_ready jsonb;
  v_n integer := 0; v_distinct integer := 0; v_bad integer := 0; v_count integer := 0; v_total numeric := 0; v_hash text; v_unready integer := 0; v_rl record;
begin
  if v_uid is null or not public.payroll_pay_can() then raise exception '権限がありません'; end if;
  if p_year_month is null or p_year_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception '月（YYYY-MM）が不正です'; end if;
  if p_corp_id is null then raise exception '法人が指定されていません'; end if;
  if p_kind is null or p_kind not in ('additional', 'retry', 'adjustment') then
    raise exception '種類が不正です（additional＝追加／retry＝再振込／adjustment＝差額。通常のバッチは payroll_transfer_batch_freeze で作ります）';
  end if;
  if p_scheduled_date is null then raise exception '振込指定日が必要です'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由を入力してください'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception '対象者と金額がありません'; end if;
  v_src := coalesce(nullif(btrim(p_account_source), ''), case when p_kind = 'retry' then 'current' else 'month' end);
  if v_src not in ('month', 'current') then raise exception '振込先の出どころが不正です（month＝給料確定のときの控え／current＝いまの登録口座）'; end if;
  perform pg_advisory_xact_lock(hashtext('payroll_transfer_batch:' || p_year_month || ':' || p_corp_id::text));

  -- 形の確かめ: 人の ID があること・同じ人が 2 回いないこと・金額が 1 円以上の整数であること
  select count(*), count(distinct e.value ->> 'user_id'),
         count(*) filter (where (e.value ->> 'user_id') is null
                             or not (case when (e.value ->> 'amount') ~ '^[0-9]+$' then (e.value ->> 'amount')::numeric > 0 else false end))
    into v_n, v_distinct, v_bad
    from jsonb_array_elements(p_lines) e;
  if v_bad > 0 then raise exception '対象者の ID が無い行、または金額が 1 円以上の整数でない行があります'; end if;
  if v_distinct <> v_n then raise exception '同じ人が 2 回入っています（同じバッチの中に、同じ人は 1 行です）'; end if;

  if p_kind in ('additional', 'adjustment') then
    if exists (select 1 from jsonb_array_elements(p_lines) e
                where not exists (select 1 from sf_payroll_sync sp join smaregi_contracts sc on sc.contract_id = sp.contract_id
                                   where sp.user_id = (e.value ->> 'user_id')::uuid and sp.year_month = p_year_month and sc.corporation_id = p_corp_id)) then
      raise exception 'その月・その法人の給与データが無い人が入っています';
    end if;
  end if;
  if p_kind = 'additional' then
    if exists (select 1 from jsonb_array_elements(p_lines) e
                where exists (select 1 from payroll_transfer_batch_lines l0
                               where l0.year_month = p_year_month and l0.corporation_id = p_corp_id and l0.user_id = (e.value ->> 'user_id')::uuid)) then
      raise exception 'すでにこの月の振込バッチに入っている人がいます（追加ではなく、差額・再振込を使ってください）';
    end if;
  end if;
  if p_kind = 'retry' then
    if exists (select 1 from jsonb_array_elements(p_lines) e
                where (e.value ->> 'retry_of_line_id') is null
                   or not exists (select 1 from payroll_transfer_batch_lines o
                                   where o.id = (e.value ->> 'retry_of_line_id')::uuid and o.user_id = (e.value ->> 'user_id')::uuid
                                     and o.year_month = p_year_month and o.corporation_id = p_corp_id and o.line_status in ('failed', 'returned'))) then
      raise exception '再振込は、同じ月・同じ法人・同じ人の「失敗・組戻しになった行」にだけ作れます（元の行の id が必要です）';
    end if;
    if exists (select 1 from jsonb_array_elements(p_lines) e
                where exists (select 1 from payroll_transfer_batch_lines r where r.retry_of_line_id = (e.value ->> 'retry_of_line_id')::uuid)) then
      raise exception 'その行には、すでに再振込のバッチがあります（1 つの元の行に、再振込は 1 つだけ。再振込も失敗したときは、その再振込の行を元にします）';
    end if;
  end if;

  -- 振込先の控え（呼ぶ側からは口座を渡さない。DB にある控え・登録口座だけを使う）
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', e.value ->> 'user_id', 'amount', (e.value ->> 'amount')::numeric,
           'retry_of_line_id', case when p_kind = 'retry' then e.value ->> 'retry_of_line_id' end, 'note', e.value ->> 'note',
           'account', case when v_src = 'month'
                           then (select m.account from payroll_month_payments m
                                  where m.user_id = (e.value ->> 'user_id')::uuid and m.year_month = p_year_month and m.status = 'fixed' and m.method = 'bank_transfer')
                           else public.payroll_account_snapshot((e.value ->> 'user_id')::uuid) end)
           order by e.value ->> 'user_id'), '[]'::jsonb)
    into v_cand
    from jsonb_array_elements(p_lines) e;
  select coalesce(jsonb_agg(e.value order by e.value ->> 'user_id'), '[]'::jsonb) into v_ready
    from jsonb_array_elements(v_cand) e
   where jsonb_typeof(e.value -> 'account') = 'object'
     and public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                       e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number') is not null
     and public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana') <> '';
  v_unready := jsonb_array_length(v_cand) - jsonb_array_length(v_ready);
  if v_unready > 0 then
    return jsonb_build_object('ok', false, 'reason', 'unready', 'unready_count', v_unready, 'account_source', v_src,
                              'message', '振込先が用意できない人がいます（給料確定のときの控え、または登録口座を確かめてください）');
  end if;

  select count(*), coalesce(sum((e.value ->> 'amount')::numeric), 0),
         encode(sha256(convert_to(coalesce(string_agg(concat_ws('|', e.value ->> 'user_id', e.value ->> 'amount',
                  public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                                e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number'),
                  public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana'),
                  coalesce(e.value ->> 'retry_of_line_id', '')), E'\n' order by e.value ->> 'user_id'), ''), 'UTF8')), 'hex')
    into v_count, v_total, v_hash
    from jsonb_array_elements(v_ready) e;

  select coalesce(max(b.batch_seq), 0) + 1 into v_seq from payroll_transfer_batches b where b.year_month = p_year_month and b.corporation_id = p_corp_id;

  perform set_config('payroll.recon_ok', '1', true);
  insert into payroll_transfer_batches(year_month, corporation_id, batch_seq, batch_kind, kind_reason, scheduled_date, expected_count, expected_total, lines_hash, frozen_by)
  values (p_year_month, p_corp_id, v_seq, p_kind, btrim(p_reason), p_scheduled_date, v_count, v_total, v_hash, v_uid)
  returning id into v_batch;
  insert into payroll_transfer_batch_lines(batch_id, year_month, corporation_id, user_id, amount, account, acct_key, kana_norm, retry_of_line_id, account_source, line_note)
  select v_batch, p_year_month, p_corp_id, (e.value ->> 'user_id')::uuid, (e.value ->> 'amount')::numeric, e.value -> 'account',
         public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                       e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number'),
         public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana'),
         (e.value ->> 'retry_of_line_id')::uuid, v_src, nullif(btrim(e.value ->> 'note'), '')
    from jsonb_array_elements(v_ready) e;
  -- 再振込: 元の行の側にも「再振込を作った」と履歴を足す（元の行そのものは変えない）
  for v_rl in
    select o.id as line_id, o.batch_id from payroll_transfer_batch_lines n join payroll_transfer_batch_lines o on o.id = n.retry_of_line_id where n.batch_id = v_batch
  loop
    perform public.payroll_recon_log(v_rl.batch_id, v_rl.line_id, 'retry_created', null, null, 'human', btrim(p_reason), jsonb_build_object('retry_batch_id', v_batch, 'retry_batch_seq', v_seq));
  end loop;
  perform public.payroll_recon_log(v_batch, null, 'frozen', null, 'planned', 'human', btrim(p_reason),
                                   jsonb_build_object('batch_seq', v_seq, 'batch_kind', p_kind, 'count', v_count, 'scheduled_date', p_scheduled_date, 'account_source', v_src));
  perform public.payroll_recon_eval(v_batch, 'auto_bank');
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'batch_id', v_batch, 'batch_seq', v_seq, 'batch_kind', p_kind, 'count', v_count, 'account_source', v_src);
end $$;
revoke all on function public.payroll_transfer_batch_freeze_custom(text, uuid, text, date, jsonb, text, text) from public, anon;
grant execute on function public.payroll_transfer_batch_freeze_custom(text, uuid, text, date, jsonb, text, text) to authenticated;

-- 銀行の取り込みの入口
create or replace function public.bank_bulk_transfer_ingest(p_transfer jsonb, p_details jsonb default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_bank text; v_key text; v_ref text; v_date date; v_cnt integer; v_total numeric; v_status text; v_raw text;
  v_t bank_bulk_transfers%rowtype; v_old bank_bulk_transfer_details%rowtype; v_d record;
  v_new boolean := false; v_changed integer := 0; v_dn integer; v_dsum numeric; v_dlines integer; v_akey text; v_kana text;
  v_batch uuid; v_evals jsonb := '[]'::jsonb; v_line uuid;
begin
  if not public.payroll_recon_can() then raise exception '権限がありません'; end if;
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
  end if;

  perform set_config('payroll.recon_ok', '1', true);
  perform pg_advisory_xact_lock(hashtext('bank_bulk_transfer:' || v_bank || ':' || v_key || ':' || v_ref));
  select * into v_t from bank_bulk_transfers t where t.bank = v_bank and t.source_account_key = v_key and t.bank_ref = v_ref for update;
  if v_t.id is null then
    insert into bank_bulk_transfers(bank, source_account_key, bank_ref, designated_date, total_count, total_amount, fee_total, bank_status_raw, bank_status, login_profile)
    values (v_bank, v_key, v_ref, v_date, v_cnt, v_total, (p_transfer ->> 'fee_total')::numeric, v_raw, v_status, p_transfer ->> 'login_profile')
    returning * into v_t;
    v_new := true;
    perform public.payroll_recon_log(null, null, 'bank_imported', null, v_status, 'auto_bank', null, jsonb_build_object('bank_transfer_id', v_t.id, 'designated_date', v_date, 'count', v_cnt));
  else
    if v_t.designated_date <> v_date or v_t.total_count <> v_cnt or v_t.total_amount <> v_total then
      raise exception '同じ受付番号なのに、振込指定日・件数・合計が前回と違います。取り込みません';
    end if;
    if v_t.bank_status is distinct from v_status then
      perform public.payroll_recon_log(v_t.batch_id, null, 'bank_status_changed', v_t.bank_status, v_status, 'auto_bank', null, jsonb_build_object('bank_transfer_id', v_t.id));
    end if;
    update bank_bulk_transfers t set bank_status = v_status, bank_status_raw = coalesce(v_raw, t.bank_status_raw), last_seen_at = now() where t.id = v_t.id
    returning * into v_t;
  end if;

  if p_details is not null then
    for v_d in
      select (d.value ->> 'line_no')::integer as line_no, d.value ->> 'bank_code' as bank_code, d.value ->> 'branch_code' as branch_code,
             d.value ->> 'account_type' as account_type, d.value ->> 'account_number' as account_number, d.value ->> 'holder_kana' as holder_kana,
             (d.value ->> 'amount')::numeric as amount, coalesce(nullif(btrim(d.value ->> 'result'), ''), 'unknown') as result, d.value ->> 'result_raw' as result_raw
        from jsonb_array_elements(p_details) d
    loop
      v_akey := public.payroll_recon_acct_key(v_d.bank_code, v_d.branch_code, v_d.account_type, v_d.account_number);
      v_kana := public.payroll_recon_kana_norm(v_d.holder_kana);
      select * into v_old from bank_bulk_transfer_details x where x.transfer_id = v_t.id and x.line_no = v_d.line_no;
      if v_old.id is null then
        insert into bank_bulk_transfer_details(transfer_id, line_no, bank_code, branch_code, account_type, account_number, holder_kana, acct_key, kana_norm, amount, result_raw, result)
        values (v_t.id, v_d.line_no, v_d.bank_code, v_d.branch_code, v_d.account_type, v_d.account_number, v_d.holder_kana, v_akey, v_kana, v_d.amount, v_d.result_raw, v_d.result);
      else
        if v_old.acct_key is distinct from v_akey or v_old.kana_norm is distinct from v_kana or v_old.amount <> v_d.amount then
          raise exception '同じ受付番号・同じ行番号なのに、振込先や金額が前回と違います。取り込みません';
        end if;
        if v_old.result is distinct from v_d.result then
          select l.id into v_line from payroll_transfer_batch_lines l where l.bank_detail_id = v_old.id;
          update bank_bulk_transfer_details x set result = v_d.result, result_raw = coalesce(v_d.result_raw, x.result_raw), last_seen_at = now() where x.id = v_old.id;
          perform public.payroll_recon_log(v_t.batch_id, v_line, 'bank_result_changed', v_old.result, v_d.result, 'auto_bank', null, jsonb_build_object('bank_transfer_id', v_t.id, 'line_no', v_d.line_no));
          v_changed := v_changed + 1;
        else
          update bank_bulk_transfer_details x set last_seen_at = now() where x.id = v_old.id;
        end if;
      end if;
    end loop;
  end if;

  -- 照合: 結び済みならそのバッチ、まだなら、振込指定日が同じで銀行取引と結んでいないバッチを順に確かめる
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

  return jsonb_build_object('ok', true, 'bank_transfer_id', v_t.id, 'new', v_new, 'results_changed', v_changed, 'batches', v_evals);
end $$;
revoke all on function public.bank_bulk_transfer_ingest(jsonb, jsonb) from public, anon;
grant execute on function public.bank_bulk_transfer_ingest(jsonb, jsonb) to authenticated, service_role;

-- ===== 2・3. 足した列と決まり（値が無いものだけ消す） =====
do $$
declare
  v_n bigint; v_col record;
  c_cols constant text[][] := array[
    ['bank_bulk_transfers', 'executed_date'], ['bank_bulk_transfers', 'grand_total'], ['bank_bulk_transfers', 'ok_count'], ['bank_bulk_transfers', 'error_count'],
    ['bank_bulk_transfers', 'memo'], ['bank_bulk_transfers', 'screen_seen_at'], ['bank_bulk_transfers', 'detail_source'], ['bank_bulk_transfers', 'result_verified_at'],
    ['bank_bulk_transfers', 'csv_sha256'], ['bank_bulk_transfers', 'csv_format'],
    ['bank_bulk_transfer_details', 'bank_name'], ['bank_bulk_transfer_details', 'branch_name'], ['bank_bulk_transfer_details', 'result_basis'], ['bank_bulk_transfer_details', 'result_checked_at'],
    ['payroll_transfer_batch_lines', 'account_compare'], ['payroll_transfer_batch_lines', 'account_choice_reason'], ['payroll_transfer_batch_lines', 'account_chosen_by']];
  v_i integer;
begin
  -- 振込先の出どころ: original の行が無ければ、元の決まりに戻す
  if to_regclass('public.payroll_transfer_batch_lines') is not null then
    select count(*) into v_n from public.payroll_transfer_batch_lines where account_source = 'original';
    if v_n = 0 then
      alter table public.payroll_transfer_batch_lines drop constraint if exists payroll_transfer_batch_lines_account_source_check;
      alter table public.payroll_transfer_batch_lines add constraint payroll_transfer_batch_lines_account_source_check check (account_source in ('month', 'current'));
    else
      raise notice '振込先の出どころが original の行が % 件あるため、決まり（month・current・original）は残しました', v_n;
    end if;
  end if;
  for v_i in 1 .. array_length(c_cols, 1) loop
    if exists (select 1 from information_schema.columns c where c.table_schema = 'public' and c.table_name = c_cols[v_i][1] and c.column_name = c_cols[v_i][2]) then
      execute format('select count(*) from public.%I where %I is not null', c_cols[v_i][1], c_cols[v_i][2]) into v_n;
      if v_n = 0 then
        -- 守りの引き金は行の書きかえを見張るもので、列を消す操作には関係しない
        execute format('alter table public.%I drop column %I', c_cols[v_i][1], c_cols[v_i][2]);
      else
        raise notice '列 %.% に値が % 件あるため、残しました', c_cols[v_i][1], c_cols[v_i][2], v_n;
      end if;
    end if;
  end loop;
end $$;
