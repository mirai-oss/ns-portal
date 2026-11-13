-- =============================================================
-- 給与振込の自動照合・追加（下書き・2026-11-13 作成。★本番未適用・1 回も流していない。適用は別の承認のあと）
--   前提: 2026-11-24_payroll_transfer_recon.sql が適用済みであること（そのファイルは編集しない）。
--   この SQL がすること（新しい表の列追加と、関数の作り直しだけ）:
--     A. 銀行の画面（WEB総振の振込結果一覧・詳細）で分かった項目を持つ列を足す
--        bank_bulk_transfers        : executed_date（実行日。振込指定日 designated_date とは別に持つ）／grand_total（合計金額＝振込金額＋手数料）／
--                                     ok_count・error_count（正常件数・エラー件数）／memo（振込メモ）／screen_seen_at（画面の表示日時）／
--                                     detail_source（明細の出どころ: screen_rows＝画面の行と CSV の行を 1 行ずつ結べた／summary＝一覧と件数だけ／none）／
--                                     result_verified_at（画面の行で結果を確かめた日時＝照合日時）／csv_sha256・csv_format（もとにした CSV の指紋と形式）
--                                     ※ 受付番号は bank_ref、手数料は fee_total として、すでにある。
--        bank_bulk_transfer_details : bank_name・branch_name（画面の表示名）／result_basis（結果の根拠: screen_row＝画面の行／summary＝一覧と件数だけ）／result_checked_at
--        payroll_transfer_batch_lines: account_compare（再振込のとき、元の振込先といまの登録口座を比べた結果: same／different）／
--                                     account_choice_reason（違うときに選んだ理由）／account_chosen_by（選んだ人）。account_source に original（元の行の控え）を足す。
--     B. 取り込みの入口 bank_bulk_transfer_ingest を作り直す
--        ・「CSV の金額が合っただけでは完了にしない」: 明細の出どころが summary（画面の行で確かめていない）のとき、行ごとの成功・失敗は受け付けない
--          （スイッチ summary_success_ok が true で、一覧が「処理済み」・正常件数＝件数・エラー 0 件のときだけ例外。既定は false＝スイッチの行に無い）。
--        ・画面の行で確かめた結果（screen_row）を、あとから来た summary の取り込みで上書きしない。
--        ・ロボット（サービス用の鍵）からの取り込みは、スイッチ bank_read_enabled が true のときだけ。明細の出どころ（detail_source）も必須。
--        ・人（本部・社長・マスター）からの今までどおりの呼び出し（detail_source なし）は、今までどおり動く。
--     C. 再振込の振込先の決め方を直す（payroll_transfer_batch_freeze_custom を作り直す）
--        いまの登録口座を無条件には使わない。元の行の振込先（控え）と、いまの登録口座を比べる。
--          (a) 同じ → そのまま使える（account_source = current・account_compare = same）
--          (b) 違う（いまの登録口座が無い・読めない場合も含む）→ 呼ぶ側が、行ごとに account_choice（original＝元の口座／current＝いまの口座）と
--              account_choice_reason（理由）を渡すまで、固めない（{ ok: false, reason: 'account_choice_required', lines: […] } を返す。口座番号は返さない）。
--        比べた結果・選んだ人・理由は、行の列と履歴（event = retry_account_decided）に残る。
--   この SQL が変えないもの: 既存の給与の表（給与データ・口座・月ごとの支払方法・支払記録）・スイッチの行・ほかの関数。
--   戻し方: 2026-11-25_payroll_transfer_recon_bankref_rollback.sql
-- =============================================================

-- ===== A. 列を足す（新しい表だけ） =====
alter table public.bank_bulk_transfers
  add column if not exists executed_date      date,
  add column if not exists grand_total        numeric,
  add column if not exists ok_count           integer,
  add column if not exists error_count        integer,
  add column if not exists memo               text,
  add column if not exists screen_seen_at     timestamptz,
  add column if not exists detail_source      text check (detail_source in ('screen_rows', 'summary', 'none')),
  add column if not exists result_verified_at timestamptz,
  add column if not exists csv_sha256         text check (csv_sha256 ~ '^[0-9a-f]{64}$'),
  add column if not exists csv_format         text check (csv_format in ('zengin', 'list'));
comment on column public.bank_bulk_transfers.executed_date is '銀行の画面の「実行日」。振込指定日（designated_date＝画面の「振込日」）とは別に持つ';
comment on column public.bank_bulk_transfers.detail_source is '明細の出どころ: screen_rows＝詳細の画面の行と CSV の行を 1 行ずつ結べた／summary＝一覧と件数だけ（行ごとの結果は確かめていない）／none＝明細なし';
comment on column public.bank_bulk_transfers.result_verified_at is '詳細の画面の行で、行ごとの結果を確かめた日時（最後に確かめた時）';

alter table public.bank_bulk_transfer_details
  add column if not exists bank_name         text,
  add column if not exists branch_name       text,
  add column if not exists result_basis      text check (result_basis in ('screen_row', 'summary')),
  add column if not exists result_checked_at timestamptz;
comment on column public.bank_bulk_transfer_details.result_basis is '結果の根拠: screen_row＝詳細の画面のその行を読んだ／summary＝一覧の状態と件数だけ。null＝出どころの指定なし（人の手での取り込み）';

alter table public.payroll_transfer_batch_lines
  add column if not exists account_compare       text check (account_compare in ('same', 'different')),
  add column if not exists account_choice_reason text,
  add column if not exists account_chosen_by     uuid;
comment on column public.payroll_transfer_batch_lines.account_compare is '再振込のとき、元の行の振込先（控え）と、固めた時点の登録口座を比べた結果（same／different）。再振込でない行は null';
-- 振込先の出どころに original（元の行の振込先の控え）を足す
alter table public.payroll_transfer_batch_lines drop constraint if exists payroll_transfer_batch_lines_account_source_check;
alter table public.payroll_transfer_batch_lines add constraint payroll_transfer_batch_lines_account_source_check check (account_source in ('month', 'current', 'original'));

-- ===== 守りの引き金（作り直し。足した 3 つの列も、固めたあとは変えられないようにする。ほかは元のまま） =====
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
       or new.retry_of_line_id is distinct from old.retry_of_line_id or new.account_source is distinct from old.account_source
       or new.account_compare is distinct from old.account_compare or new.account_choice_reason is distinct from old.account_choice_reason
       or new.account_chosen_by is distinct from old.account_chosen_by then
      raise exception '固めた予定者の行（金額・振込先の控え・再振込の元の行・振込先の選び方）は変えられません';
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

-- ===== C. 追加・再振込・差額のバッチを固める（作り直し。変えたのは、再振込の振込先の決め方だけ） =====
--   p_kind : additional＝追加／retry＝再振込／adjustment＝差額（決まりは元のまま）
--   p_lines: [ { "user_id": "…", "amount": 12345, "retry_of_line_id": "…"（再振込のときだけ必須）, "note": "…"（任意）,
--               "account_choice": "original" | "current"（再振込で、元の口座といまの口座が違うときだけ必須）,
--               "account_choice_reason": "…"（同上。理由） }, … ]
--   p_account_source: 追加・差額だけ（month＝給料確定のときの控え〈既定〉／current＝いまの登録口座）。再振込では指定できない（行ごとに決めるため）。
--   再振込の振込先:
--     元の行の振込先（固めたときの控え）と、いまの登録口座を「金融機関・支店・種別・口座番号＋名義カナ」で比べる。
--       同じ → いまの登録口座を使う（account_source = current・account_compare = same）。選ぶ必要はない。
--       違う（いまの登録口座が無い・読めない場合も含む）→ account_choice と account_choice_reason が、その行にあるときだけ固める。
--          original → 元の行の控えを使う（account_source = original）／current → いまの登録口座を使う（account_source = current）。account_compare = different。
--          1 人でも足りなければ、だれも固めずに { ok: false, reason: 'account_choice_required', lines: [ { user_id, retry_of_line_id, compare, current_available, diff, missing } ] } を返す。
--   比べた結果・選んだ人・理由は、行（account_compare・account_chosen_by・account_choice_reason）と履歴（retry_account_decided）に残る。口座番号・名義は履歴に入れない。
create or replace function public.payroll_transfer_batch_freeze_custom(p_year_month text, p_corp_id uuid, p_kind text, p_scheduled_date date, p_lines jsonb, p_reason text,
                                                                       p_account_source text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); v_src text; v_seq integer; v_batch uuid; v_cand jsonb; v_ready jsonb;
  v_n integer := 0; v_distinct integer := 0; v_bad integer := 0; v_count integer := 0; v_total numeric := 0; v_hash text; v_unready integer := 0; v_rl record;
  v_e jsonb; v_cur jsonb; v_cur_key text; v_cur_kana text; v_cur_ok boolean; v_same boolean; v_choice text; v_choice_reason text; v_need jsonb := '[]'::jsonb;
  v_n_same integer := 0; v_n_diff integer := 0;
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
  if p_kind = 'retry' then
    if nullif(btrim(p_account_source), '') is not null then
      raise exception '再振込では、振込先の出どころをまとめて指定できません（元の口座といまの口座が違う人は、行ごとに account_choice と account_choice_reason を渡してください）';
    end if;
    v_src := null;
  else
    v_src := coalesce(nullif(btrim(p_account_source), ''), 'month');
    if v_src not in ('month', 'current') then raise exception '振込先の出どころが不正です（month＝給料確定のときの控え／current＝いまの登録口座）'; end if;
  end if;
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
    if exists (select 1 from jsonb_array_elements(p_lines) e
                where nullif(btrim(e.value ->> 'account_choice'), '') is not null and btrim(e.value ->> 'account_choice') not in ('original', 'current')) then
      raise exception '振込先の選び方（account_choice）が不正です（original＝元の口座／current＝いまの登録口座）';
    end if;
  end if;

  if p_kind = 'retry' then
    -- 再振込: 元の行の振込先（控え）と、いまの登録口座を比べて決める（呼ぶ側からは、口座そのものは渡さない）
    v_ready := '[]'::jsonb;
    for v_e in
      select jsonb_build_object('user_id', e.value ->> 'user_id', 'amount', (e.value ->> 'amount')::numeric, 'retry_of_line_id', e.value ->> 'retry_of_line_id',
                                'note', e.value ->> 'note', 'choice', nullif(btrim(e.value ->> 'account_choice'), ''),
                                'choice_reason', nullif(btrim(e.value ->> 'account_choice_reason'), ''),
                                'orig', o.account, 'orig_key', o.acct_key, 'orig_kana', o.kana_norm,
                                'cur', public.payroll_account_snapshot((e.value ->> 'user_id')::uuid))
        from jsonb_array_elements(p_lines) e
        join payroll_transfer_batch_lines o on o.id = (e.value ->> 'retry_of_line_id')::uuid
       order by e.value ->> 'user_id'
    loop
      v_cur := v_e -> 'cur';
      v_cur_key := null; v_cur_kana := '';
      if jsonb_typeof(v_cur) = 'object' then
        v_cur_key := public.payroll_recon_acct_key(v_cur ->> 'bank_code', v_cur ->> 'branch_code', v_cur ->> 'account_type', v_cur ->> 'account_number');
        v_cur_kana := public.payroll_recon_kana_norm(v_cur ->> 'account_holder_kana');
      end if;
      v_cur_ok := v_cur_key is not null and v_cur_kana <> '';
      v_same := v_cur_ok and v_cur_key = (v_e ->> 'orig_key') and v_cur_kana = (v_e ->> 'orig_kana');
      v_choice := v_e ->> 'choice';
      v_choice_reason := v_e ->> 'choice_reason';
      if v_same then
        -- (a) 同じ: そのまま使える
        v_n_same := v_n_same + 1;
        v_ready := v_ready || jsonb_build_array(jsonb_build_object('user_id', v_e ->> 'user_id', 'amount', v_e -> 'amount', 'retry_of_line_id', v_e ->> 'retry_of_line_id',
                     'note', v_e ->> 'note', 'account', v_cur, 'source', 'current', 'compare', 'same', 'choice_reason', v_choice_reason, 'chosen', false));
      elsif v_choice is null or v_choice_reason is null then
        -- (b) 違う: 呼ぶ側が選ぶ（理由つき）まで、固めない。何が違うかだけ返す（口座番号・名義は返さない）
        v_need := v_need || jsonb_build_array(jsonb_build_object(
                    'user_id', v_e ->> 'user_id', 'retry_of_line_id', v_e ->> 'retry_of_line_id', 'compare', 'different', 'current_available', v_cur_ok,
                    'diff', case when v_cur_ok then jsonb_build_object(
                                   'bank', split_part(v_cur_key, '-', 1) <> split_part(v_e ->> 'orig_key', '-', 1),
                                   'branch', split_part(v_cur_key, '-', 2) <> split_part(v_e ->> 'orig_key', '-', 2),
                                   'type', split_part(v_cur_key, '-', 3) <> split_part(v_e ->> 'orig_key', '-', 3),
                                   'number', split_part(v_cur_key, '-', 4) <> split_part(v_e ->> 'orig_key', '-', 4),
                                   'kana', v_cur_kana <> (v_e ->> 'orig_kana')) end,
                    'missing', case when v_choice is null then 'account_choice' else 'account_choice_reason' end));
      elsif v_choice = 'current' and not v_cur_ok then
        v_unready := v_unready + 1;   -- 「いまの口座」を選んだが、登録口座が無い・読めない
      else
        v_n_diff := v_n_diff + 1;
        v_ready := v_ready || jsonb_build_array(jsonb_build_object('user_id', v_e ->> 'user_id', 'amount', v_e -> 'amount', 'retry_of_line_id', v_e ->> 'retry_of_line_id',
                     'note', v_e ->> 'note', 'account', case when v_choice = 'original' then v_e -> 'orig' else v_cur end,
                     'source', v_choice, 'compare', 'different', 'choice_reason', v_choice_reason, 'chosen', true));
      end if;
    end loop;
    if jsonb_array_length(v_need) > 0 then
      return jsonb_build_object('ok', false, 'reason', 'account_choice_required', 'lines', v_need,
                                'message', '元の振込先と、いまの登録口座が違う人がいます。行ごとに、元の口座（original）・いまの口座（current）のどちらへ振り込むかと、その理由を指定してください');
    end if;
    if v_unready > 0 then
      return jsonb_build_object('ok', false, 'reason', 'unready', 'unready_count', v_unready,
                                'message', '「いまの口座」を選んだ人の中に、登録口座が無い・読めない人がいます（登録口座を確かめるか、元の口座を選んでください）');
    end if;
  else
    -- 追加・差額: 元のまま（呼ぶ側からは口座を渡さない。DB にある控え・登録口座だけを使う）
    select coalesce(jsonb_agg(jsonb_build_object(
             'user_id', e.value ->> 'user_id', 'amount', (e.value ->> 'amount')::numeric,
             'retry_of_line_id', null::text, 'note', e.value ->> 'note',
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
  insert into payroll_transfer_batch_lines(batch_id, year_month, corporation_id, user_id, amount, account, acct_key, kana_norm, retry_of_line_id, account_source, line_note,
                                           account_compare, account_choice_reason, account_chosen_by)
  select v_batch, p_year_month, p_corp_id, (e.value ->> 'user_id')::uuid, (e.value ->> 'amount')::numeric, e.value -> 'account',
         public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                       e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number'),
         public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana'),
         (e.value ->> 'retry_of_line_id')::uuid, coalesce(e.value ->> 'source', v_src), nullif(btrim(e.value ->> 'note'), ''),
         e.value ->> 'compare',
         case when (e.value ->> 'chosen')::boolean then e.value ->> 'choice_reason' end,
         case when (e.value ->> 'chosen')::boolean then v_uid end
    from jsonb_array_elements(v_ready) e;
  -- 再振込: 元の行の側にも「再振込を作った」と履歴を足す（元の行そのものは変えない）。新しい行の側には、振込先をどう決めたかを残す（口座番号・名義は入れない）
  for v_rl in
    select o.id as line_id, o.batch_id, n.id as new_line_id, n.account_source, n.account_compare, n.account_choice_reason, n.account_chosen_by
      from payroll_transfer_batch_lines n join payroll_transfer_batch_lines o on o.id = n.retry_of_line_id where n.batch_id = v_batch
  loop
    perform public.payroll_recon_log(v_rl.batch_id, v_rl.line_id, 'retry_created', null, null, 'human', btrim(p_reason), jsonb_build_object('retry_batch_id', v_batch, 'retry_batch_seq', v_seq));
    perform public.payroll_recon_log(v_batch, v_rl.new_line_id, 'retry_account_decided', null, null, 'human', v_rl.account_choice_reason,
                                     jsonb_build_object('retry_of_line_id', v_rl.line_id, 'account_compare', v_rl.account_compare, 'account_source', v_rl.account_source,
                                                        'chosen_by', v_rl.account_chosen_by));
  end loop;
  perform public.payroll_recon_log(v_batch, null, 'frozen', null, 'planned', 'human', btrim(p_reason),
                                   jsonb_build_object('batch_seq', v_seq, 'batch_kind', p_kind, 'count', v_count, 'scheduled_date', p_scheduled_date, 'account_source', v_src,
                                                      'account_same', v_n_same, 'account_different', v_n_diff));
  perform public.payroll_recon_eval(v_batch, 'auto_bank');
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'batch_id', v_batch, 'batch_seq', v_seq, 'batch_kind', p_kind, 'count', v_count, 'account_source', v_src,
                            'account_compare', case when p_kind = 'retry' then jsonb_build_object('same', v_n_same, 'different', v_n_diff) end);
end $$;
revoke all on function public.payroll_transfer_batch_freeze_custom(text, uuid, text, date, jsonb, text, text) from public, anon;
grant execute on function public.payroll_transfer_batch_freeze_custom(text, uuid, text, date, jsonb, text, text) to authenticated;

-- ===== B. 銀行の取り込みの入口（作り直し） =====
--   p_transfer: { bank?, source_account_key, bank_ref（受付番号）, designated_date（振込日）, total_count, total_amount（振込金額）, fee_total?（手数料）, bank_status, bank_status_raw?, login_profile?,
--                 ここから下が、この SQL で足したもの:
--                 detail_source?（screen_rows／summary／none。ロボットからは必須）, executed_date?（実行日）, grand_total?（合計金額）, ok_count?, error_count?, memo?, screen_seen_at?,
--                 csv_sha256?, csv_format? }
--   p_details : [ { line_no（明細番号）, bank_code, branch_code, account_type, account_number, holder_kana, amount, result, result_raw?, bank_name?, branch_name? }, … ]（null＝明細はまだ読めていない）
--   元からの決まり（そのまま）: 同じ受付番号の再投入では行は増えない／明細の件数・合計が総合振込と合わなければ取り込まない／同じ受付番号で指定日・件数・合計・振込先・金額が違えば取り込まない。
--   足した決まり:
--     ・ロボット（サービス用の鍵）: スイッチ bank_read_enabled が true のときだけ。detail_source が必須。
--     ・手数料と合計金額の両方があるとき、「振込金額＋手数料＝合計金額」でなければ取り込まない。
--     ・detail_source = summary（画面の行で確かめていない）: 行ごとの成功・失敗・組戻しは受け付けない（unknown・processing・accepted だけ）。
--         例外は、スイッチ summary_success_ok が true で、状態が done・正常件数＝件数・エラー件数 0・全行が成功のときだけ（既定は false）。
--       → CSV の件数・合計が合っただけでは、行は「成功」にならず、バッチは「確認待ち（銀行の結果が確定していない）」で止まる。
--     ・detail_source = screen_rows: 正常件数（ok_count）があれば、行ごとの成功の数と同じであること。result_verified_at に日時を入れる。
--     ・画面の行で確かめた結果（result_basis = screen_row）は、あとから来た summary の取り込みでは変えない。
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
