-- =============================================================
-- 給与振込の自動照合・追加 2（下書き・2026-11-13 作成。★本番未適用。適用は別の承認のあと）
--   「人による取り込み」の道: 給与の担当者（本部・社長・マスター）が、銀行の画面から自分で落とした CSV と、
--   結果の画面に出ている情報（受付番号・実行日・件数・正常件数・エラー件数・振込金額・手数料・合計・状態）を、ポータルから登録できるようにする。
--   前提: 2026-11-24_payroll_transfer_recon.sql と 2026-11-25_payroll_transfer_recon_bankref.sql が適用済みであること（どちらも編集しない）。
--
--   この SQL がすること
--     A. 新しい表に列を足す: bank_bulk_transfers.entered_by・entered_at（人が画面を見て入れた値を、だれが・いつ入れたか）。
--        明細の出どころに csv_upload（人が登録した CSV）を足す（bank_bulk_transfers.detail_source・bank_bulk_transfer_details.result_basis）。
--     B. 証憑の置き場: 非公開のバケット payroll-transfer-evidence（CSV と PDF だけ・20MB）。
--        読む＝payroll_pay_can()（本部・社長・マスター）／入れる＝payroll_pay_can()（新しいファイルだけ）。上書き・消すの決まりは作らない＝だれも上書き・削除できない。
--     C. 照合（payroll_recon_eval）の作り直し: 人が確認済みで、銀行の明細と結べている行を扱えるようにする。
--     D. 取り込みの入口（bank_bulk_transfer_ingest）の作り直し: csv_upload を足す。
--     E〜H. 新しい関数:
--        payroll_transfer_bank_csv_register      … 人による取り込みの入口（明細の結果は必ず「不明」）
--        payroll_transfer_manual_confirm_matched … 口座・名義・金額が 1 対 1 で合っている行を、まとめて「人が確認済み」にする（条件つき）
--        payroll_transfer_recon_status           … 画面用。今までの戻り値はそのまま、受付番号・実行日・金額・件数・差・不一致の理由などを足す
--   守っていること
--     ・CSV の金額が合っただけでは、だれも「振込完了」にならない（CSV の登録では、行の結果は「不明」のまま。完了にするには、人が根拠と理由を書いて確認する）。
--     ・人の確認による完了は「振込完了（手動確認）」（completed_kind = manual・bank_matched_at は空）。自動（auto）・照合済みを人が完了（human）とは別に残る。
--     ・スイッチ auto_complete とは無関係（人の操作としてだけ動く）。Slack 用の関数は変えていない（金額・口座・氏名・ファイルの場所は返さない）。
--     ・既存の給与の表（給与データ・口座・月ごとの支払方法・支払記録 paid_at・給料確定）・スイッチの行には、触れない。
--   戻し方: 2026-11-27_payroll_transfer_recon_upload_rollback.sql
-- =============================================================

-- ===== A. 列と決まり（新しい表だけ） =====
alter table public.bank_bulk_transfers
  add column if not exists entered_by uuid,
  add column if not exists entered_at timestamptz;
comment on column public.bank_bulk_transfers.entered_by is '人が銀行の画面を見て入れた値（受付番号・実行日・件数・手数料・状態など）を、最後に登録した人。取得ジョブが読んだ取引では null';
-- 明細の出どころ・結果の根拠の決まりに csv_upload を足す（前の決まりは、名前に頼らず「その列の check」を探して外してから、付け直す）
do $$
declare v_c record;
begin
  for v_c in
    select c.conrelid::regclass as tbl, c.conname
      from pg_constraint c
     where c.contype = 'c'
       and ((c.conrelid = 'public.bank_bulk_transfers'::regclass and pg_get_constraintdef(c.oid) like '%detail_source%')
         or (c.conrelid = 'public.bank_bulk_transfer_details'::regclass and pg_get_constraintdef(c.oid) like '%result_basis%'))
  loop
    execute format('alter table %s drop constraint %I', v_c.tbl, v_c.conname);
  end loop;
end $$;
alter table public.bank_bulk_transfers add constraint bank_bulk_transfers_detail_source_check check (detail_source in ('screen_rows', 'summary', 'none', 'csv_upload'));
alter table public.bank_bulk_transfer_details add constraint bank_bulk_transfer_details_result_basis_check check (result_basis in ('screen_row', 'summary', 'csv_upload'));

-- ===== B. 証憑の置き場（Storage の非公開バケット。請求書 invoice-files・給与明細 payroll-pdfs と同じ作り方） =====
--   置き場所の形: {法人コード}/{対象月}/{バッチの連番}/{種類}_{登録日時}_{SHA-256 の先頭 12 文字}.csv（ファイル名に氏名・口座を入れない）
--   給与明細の payroll-pdfs は本人も読めるので、使わない。
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payroll-transfer-evidence', 'payroll-transfer-evidence', false, 20971520, array['text/csv', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = 20971520, allowed_mime_types = array['text/csv', 'application/pdf'];

drop policy if exists payroll_transfer_evidence_read on storage.objects;
create policy payroll_transfer_evidence_read on storage.objects for select
  using (bucket_id = 'payroll-transfer-evidence' and public.payroll_pay_can());
drop policy if exists payroll_transfer_evidence_insert on storage.objects;
create policy payroll_transfer_evidence_insert on storage.objects for insert
  with check (bucket_id = 'payroll-transfer-evidence' and public.payroll_pay_can());
-- update・delete の決まりは作らない（ログインした人は、上書きも削除もできない）

-- ===== C. 照合（内部用・作り直し）: 元は 2026-11-24。変えたのは「人が確認済みで、銀行の明細と結べている行」の扱いだけ =====
--   ・人が確認済みの行は、銀行の結果が「失敗・組戻し」でない限り、状態を変えない（今までは、銀行の明細と結べた行は必ず銀行の結果で上書きしていた）。
--   ・人が確認済みの行は「結果がまだ」の数に入れない。人の確認を 1 人でも含んで全員が決まれば「振込完了（手動確認）」。bank_matched_at は入れない。
create or replace function public.payroll_recon_eval(p_batch_id uuid, p_actor_kind text default 'auto_bank')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_b payroll_transfer_batches%rowtype; v_t bank_bulk_transfers%rowtype; v_allowed jsonb;
  v_exact integer; v_full integer; v_near integer; v_exact_ids uuid[]; v_full_ids uuid[]; v_pick uuid; v_l record; v_cnt integer; v_did uuid; v_reason text;
  v_total integer; v_linked integer; v_manual integer; v_manual_linked integer; v_failed integer; v_notfinal integer; v_extra integer; v_counts jsonb;
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
    elsif v_l.line_status = 'manual_confirmed' then
      null;   -- 2026-11-27: 人が確認済みの行は、銀行の結果が「失敗・組戻し」でない限り、そのまま（手動確認の記録を残す。自動照合の「成功」とは別のまま）
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
         count(*) filter (where l.bank_detail_id is not null and l.line_status <> 'manual_confirmed' and d.result not in ('success', 'failed', 'returned')),
         count(*) filter (where l.bank_detail_id is not null and l.line_status = 'manual_confirmed')
    into v_total, v_linked, v_manual, v_failed, v_notfinal, v_manual_linked
    from payroll_transfer_batch_lines l left join bank_bulk_transfer_details d on d.id = l.bank_detail_id
   where l.batch_id = v_b.id;
  select count(*) into v_extra from bank_bulk_transfer_details d
   where d.transfer_id = v_t.id and not exists (select 1 from payroll_transfer_batch_lines l where l.bank_detail_id = d.id);
  v_counts := jsonb_build_object('people', v_total, 'linked', v_linked, 'manual', v_manual, 'failed', v_failed, 'not_final', v_notfinal, 'bank_extra', v_extra, 'manual_linked', v_manual_linked);

  if v_failed > 0 then
    perform public.payroll_recon_set_batch(v_b.id, 'failed', 'bank_failed_or_returned', p_actor_kind, v_counts);
  elsif v_linked + v_manual < v_total then
    perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'lines_not_matched', p_actor_kind, v_counts);
  elsif v_extra > v_manual then
    perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'bank_has_extra_details', p_actor_kind, v_counts);
  elsif v_notfinal > 0 or v_t.bank_status <> 'done' then
    perform public.payroll_recon_set_batch(v_b.id, 'pending_check', 'bank_result_not_final', p_actor_kind, v_counts);
  elsif v_manual + v_manual_linked > 0 then
    perform public.payroll_recon_complete(v_b.id, 'manual', p_actor_kind, null);   -- 人の確認を 1 人でも含む → 「振込完了（手動確認）」。bank_matched_at は入れない＝自動照合とは区別がつく
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

-- ===== D. 銀行の取り込みの入口（作り直し）: 元は 2026-11-25。足したのは、人による CSV の登録（csv_upload）と、行番号の付け直しだけ =====
--   ・csv_upload は、下の payroll_transfer_bank_csv_register の中からだけ使える。結果は「不明」だけ。すでにある行の結果は変えない。
--   ・画面の行で確かめた取引（screen_rows）は、csv_upload では書きかえない。csv_upload の取引は、あとから screen_rows で書きかえられる。
--   ・だれが・いつ入れたか（entered_by・entered_at）を残す。
create or replace function public.bank_bulk_transfer_ingest(p_transfer jsonb, p_details jsonb default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_bank text; v_key text; v_ref text; v_date date; v_cnt integer; v_total numeric; v_status text; v_raw text;
  v_t bank_bulk_transfers%rowtype; v_old bank_bulk_transfer_details%rowtype; v_d record;
  v_new boolean := false; v_changed integer := 0; v_dn integer; v_dsum numeric; v_dlines integer; v_akey text; v_kana text;
  v_batch uuid; v_evals jsonb := '[]'::jsonb; v_line uuid;
  v_service boolean := public.payroll_recon_is_service(); v_src text; v_exec date; v_fee numeric; v_grand numeric; v_okc integer; v_errc integer;
  v_seen timestamptz; v_sha text; v_fmt text; v_basis text; v_nsucc integer := 0; v_nfinal integer := 0;
  v_keep boolean := false; v_nknown integer := 0; v_uid uuid := auth.uid();
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
  if v_src is not null and v_src not in ('screen_rows', 'summary', 'none', 'csv_upload') then raise exception '明細の出どころ（detail_source）の値が不正です: %', v_src; end if;
  -- 2026-11-27: csv_upload（人が銀行の画面から落とした CSV の登録）は、payroll_transfer_bank_csv_register の中からだけ（ロボット・直接の呼び出しでは使えない）
  if v_src = 'csv_upload' and (v_uid is null or coalesce(current_setting('payroll.csv_register', true), '') <> '1') then
    raise exception '人による CSV の登録は、payroll_transfer_bank_csv_register から行ってください';
  end if;
  if v_service and v_src is null then raise exception 'ロボットからの取り込みには、明細の出どころ（detail_source）が必要です'; end if;
  if v_src = 'none' and p_details is not null then raise exception '明細の出どころが none なのに、明細が渡されています'; end if;
  if v_src in ('screen_rows', 'summary', 'csv_upload') and p_details is null then raise exception '明細の出どころが % なのに、明細がありません', v_src; end if;
  if v_fee is not null and v_grand is not null and v_total + v_fee <> v_grand then
    raise exception '「振込金額＋手数料」が「合計金額」と合いません。取り込みません';
  end if;
  if v_sha is not null and v_sha !~ '^[0-9a-f]{64}$' then raise exception 'CSV の指紋（SHA-256）の形が不正です'; end if;
  if v_fmt is not null and v_fmt not in ('zengin', 'list') then raise exception 'CSV の形式の値が不正です'; end if;
  v_basis := case v_src when 'screen_rows' then 'screen_row' when 'summary' then 'summary' when 'csv_upload' then 'csv_upload' else null end;

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
    select count(*) filter (where coalesce(nullif(btrim(d.value ->> 'result'), ''), 'unknown') <> 'unknown') into v_nknown from jsonb_array_elements(p_details) d;
    if v_src = 'csv_upload' and v_nknown > 0 then
      raise exception 'CSV には 1 件ごとの結果が入っていないので、結果は「不明」でしか登録できません（CSV の金額が合っただけでは、成功にしません）';
    end if;
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
                                    executed_date, grand_total, ok_count, error_count, memo, screen_seen_at, detail_source, result_verified_at, csv_sha256, csv_format,
                                    entered_by, entered_at)
    values (v_bank, v_key, v_ref, v_date, v_cnt, v_total, v_fee, v_raw, v_status, p_transfer ->> 'login_profile',
            v_exec, v_grand, v_okc, v_errc, nullif(btrim(p_transfer ->> 'memo'), ''), v_seen, v_src, case when v_src = 'screen_rows' then now() end, v_sha, v_fmt,
            case when v_src = 'csv_upload' then v_uid end, case when v_src = 'csv_upload' then now() end)
    returning * into v_t;
    v_new := true;
    perform public.payroll_recon_log(null, null, 'bank_imported', null, v_status, case when v_src = 'csv_upload' then 'human' else 'auto_bank' end, null,
                                     jsonb_build_object('bank_transfer_id', v_t.id, 'designated_date', v_date, 'count', v_cnt, 'detail_source', v_src));
  else
    if v_t.designated_date <> v_date or v_t.total_count <> v_cnt or v_t.total_amount <> v_total then
      raise exception '同じ受付番号なのに、振込指定日・件数・合計が前回と違います。取り込みません';
    end if;
    -- 2026-11-27: 取得ジョブが画面の行で確かめた取引は、人の登録では書きかえない（逆はできる）。
    --   ★ coalesce が要る: 出どころの指定なし（v_src が null）のとき、ここが null になると、下の「not v_keep」も null になって、明細の更新がまるごと飛んでしまう。
    v_keep := coalesce(v_src = 'csv_upload' and v_t.detail_source = 'screen_rows', false);
    -- 取得ジョブが銀行の一覧で「エラー」の状態を読んだ取引を、人の登録で「正常」などに戻すことはできない（失敗の知らせを消さない）
    if v_src = 'csv_upload' and v_t.detail_source = 'summary' and v_t.bank_status in ('failed', 'partial') and v_status not in ('failed', 'partial') then
      raise exception 'この受付番号は、取得ジョブが銀行の一覧で「エラー」の状態を読んでいます。人の登録では、ほかの状態に変えられません（取得ジョブで読み直してください）';
    end if;
    if v_keep and (v_status in ('failed', 'partial') or coalesce(v_errc, 0) > 0) then
      -- 「失敗」の知らせは、どの出どころ・どの順番でも反映する: 取引の状態と件数だけを入れる（画面の行で確かめた明細の結果は変えない）→ 照合で「確認待ち」になる
      if v_t.bank_status is distinct from v_status then
        perform public.payroll_recon_log(v_t.batch_id, null, 'bank_status_changed', v_t.bank_status, v_status, 'human', null, jsonb_build_object('bank_transfer_id', v_t.id, 'over_screen_rows', true));
      end if;
      update bank_bulk_transfers t
         set bank_status = v_status, bank_status_raw = coalesce(v_raw, t.bank_status_raw), ok_count = coalesce(v_okc, t.ok_count), error_count = coalesce(v_errc, t.error_count),
             entered_by = v_uid, entered_at = now(), last_seen_at = now(), csv_sha256 = coalesce(t.csv_sha256, v_sha), csv_format = coalesce(t.csv_format, v_fmt)
       where t.id = v_t.id
      returning * into v_t;
    elsif v_keep then
      update bank_bulk_transfers t set last_seen_at = now(), csv_sha256 = coalesce(t.csv_sha256, v_sha), csv_format = coalesce(t.csv_format, v_fmt) where t.id = v_t.id
      returning * into v_t;
    else
    if v_t.bank_status is distinct from v_status then
      perform public.payroll_recon_log(v_t.batch_id, null, 'bank_status_changed', v_t.bank_status, v_status, case when v_src = 'csv_upload' then 'human' else 'auto_bank' end, null, jsonb_build_object('bank_transfer_id', v_t.id));
    end if;
    update bank_bulk_transfers t
       set bank_status = v_status, bank_status_raw = coalesce(v_raw, t.bank_status_raw), last_seen_at = now(),
           fee_total = coalesce(v_fee, t.fee_total), executed_date = coalesce(v_exec, t.executed_date), grand_total = coalesce(v_grand, t.grand_total),
           ok_count = coalesce(v_okc, t.ok_count), error_count = coalesce(v_errc, t.error_count), memo = coalesce(nullif(btrim(p_transfer ->> 'memo'), ''), t.memo),
           screen_seen_at = coalesce(v_seen, t.screen_seen_at),
           -- 画面の行で確かめたことがあれば、あとから summary・none が来ても「screen_rows」のまま
           -- 取得ジョブが読んだ取引（screen_rows・summary）の出どころは、人の登録（csv_upload）では書きかえない
           detail_source = case when t.detail_source = 'screen_rows' then 'screen_rows' when t.detail_source = 'summary' and v_src = 'csv_upload' then 'summary'
                                when v_src in ('screen_rows', 'summary', 'csv_upload') then v_src else coalesce(t.detail_source, v_src) end,
           entered_by = case when v_src = 'csv_upload' then v_uid else t.entered_by end, entered_at = case when v_src = 'csv_upload' then now() else t.entered_at end,
           result_verified_at = case when v_src = 'screen_rows' then now() else t.result_verified_at end,
           csv_sha256 = coalesce(v_sha, t.csv_sha256), csv_format = coalesce(v_fmt, t.csv_format)
     where t.id = v_t.id
    returning * into v_t;
    end if;
  end if;

  -- 2026-11-27: 画面の行で確かめた結果（screen_rows）が、人の登録・一覧だけの取り込みのあとから来たとき、行番号（CSV の並び順）が画面の明細番号と違っていても取り込めるようにする。
  --   口座の鍵＋名義＋金額が、前回の明細と 1 対 1 で同じときだけ、行番号を付け直す（中身が違えば、今までどおり取り込まない）。
  if p_details is not null and v_src = 'screen_rows' and not v_new
     and exists (select 1 from bank_bulk_transfer_details x where x.transfer_id = v_t.id)
     and not exists (select 1 from bank_bulk_transfer_details x where x.transfer_id = v_t.id and x.result_basis = 'screen_row')
     and exists (select 1 from jsonb_array_elements(p_details) d
                   join bank_bulk_transfer_details x on x.transfer_id = v_t.id and x.line_no = (d.value ->> 'line_no')::integer
                  where x.acct_key is distinct from public.payroll_recon_acct_key(d.value ->> 'bank_code', d.value ->> 'branch_code', d.value ->> 'account_type', d.value ->> 'account_number')
                     or x.kana_norm is distinct from public.payroll_recon_kana_norm(d.value ->> 'holder_kana')
                     or x.amount <> (d.value ->> 'amount')::numeric) then
    if (select count(*) from bank_bulk_transfer_details x where x.transfer_id = v_t.id) <> v_dn
       or (select count(distinct public.payroll_recon_acct_key(d.value ->> 'bank_code', d.value ->> 'branch_code', d.value ->> 'account_type', d.value ->> 'account_number')
                                 || '|' || public.payroll_recon_kana_norm(d.value ->> 'holder_kana') || '|' || ((d.value ->> 'amount')::numeric)::text)
             from jsonb_array_elements(p_details) d) <> v_dn
       or exists (select 1 from jsonb_array_elements(p_details) d
                   where (select count(*) from bank_bulk_transfer_details x
                           where x.transfer_id = v_t.id
                             and x.acct_key = public.payroll_recon_acct_key(d.value ->> 'bank_code', d.value ->> 'branch_code', d.value ->> 'account_type', d.value ->> 'account_number')
                             and x.kana_norm = public.payroll_recon_kana_norm(d.value ->> 'holder_kana') and x.amount = (d.value ->> 'amount')::numeric) <> 1) then
      raise exception '同じ受付番号なのに、明細の中身（振込先・金額）が前回の登録と違います。取り込みません';
    end if;
    update bank_bulk_transfer_details x set line_no = -x.line_no - 1000000 where x.transfer_id = v_t.id;   -- いったん、重ならない番号へよける
    update bank_bulk_transfer_details x
       set line_no = n.line_no
      from (select (d.value ->> 'line_no')::integer as line_no,
                   public.payroll_recon_acct_key(d.value ->> 'bank_code', d.value ->> 'branch_code', d.value ->> 'account_type', d.value ->> 'account_number') as akey,
                   public.payroll_recon_kana_norm(d.value ->> 'holder_kana') as kana, (d.value ->> 'amount')::numeric as amount
              from jsonb_array_elements(p_details) d) n
     where x.transfer_id = v_t.id and x.acct_key = n.akey and x.kana_norm = n.kana and x.amount = n.amount;
    perform public.payroll_recon_log(v_t.batch_id, null, 'bank_lines_renumbered', null, null, 'auto_bank', null, jsonb_build_object('bank_transfer_id', v_t.id, 'count', v_dn));
  end if;

  -- 2026-11-27: 画面の行で確かめた取引に、人が CSV を登録し直したとき: 明細には触らない。中身（振込先・金額）が同じことだけ確かめる
  if p_details is not null and v_keep then
    if exists (select 1 from jsonb_array_elements(p_details) d
                where not exists (select 1 from bank_bulk_transfer_details x
                                   where x.transfer_id = v_t.id
                                     and x.acct_key = public.payroll_recon_acct_key(d.value ->> 'bank_code', d.value ->> 'branch_code', d.value ->> 'account_type', d.value ->> 'account_number')
                                     and x.kana_norm = public.payroll_recon_kana_norm(d.value ->> 'holder_kana') and x.amount = (d.value ->> 'amount')::numeric)) then
      raise exception '同じ受付番号なのに、CSV の明細の中身（振込先・金額）が、取得ジョブが画面で読んだ内容と違います。取り込みません';
    end if;
  end if;

  if p_details is not null and not v_keep then
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
        if v_d.result not in ('failed', 'returned')
           and (coalesce(v_basis, '') = 'csv_upload' or (coalesce(v_basis, '') = 'summary' and coalesce(v_old.result_basis, '') = 'screen_row')) then
          -- 画面の行で確かめた結果は、一覧と件数だけの取り込みでは変えない。人による CSV の登録（結果は「不明」）は、すでにある行の結果を変えない。
          -- ただし「失敗・組戻し」は、どの出どころ・どの順番でも必ず反映する（この枝には入らず、下の更新へ進む）。出どころの指定なし（v_basis が null）も、下の更新へ進む
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

-- ===== E. 画面用の関数の「元の中身」（2026-11-24 の定義を、名前だけ _base に変えて残す。内部用。中身は 1 文字も変えていない） =====
create or replace function public.payroll_transfer_recon_status_base(p_year_month text, p_corp_id uuid default null)
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
revoke all on function public.payroll_transfer_recon_status_base(text, uuid) from public, anon, authenticated;

-- ===== F. 人による取り込みの入口（給与の担当者が、銀行の画面から落とした CSV と、画面に出ている情報を登録する） =====
--   p_transfer: { bank_ref（受付番号）, designated_date（振込日）, executed_date（実行日）, total_count（振込件数）, total_amount（振込金額）, ok_count（正常件数）, error_count（エラー件数）,
--                 bank_status（processing／done／failed／partial／unknown）, bank_status_raw?（画面の言葉）, fee_total?（手数料）, grand_total?（合計金額）, memo?,
--                 source_account_key?（出金口座の印。全銀形式の CSV のヘッダーから画面が作る）, corporation_id?（印が無いとき、その法人の印が 1 つだけ登録されていればそれを使う）,
--                 csv_designated_md?（全銀形式の CSV のヘッダーの振込指定日＝月日 4 桁。全銀形式では必須） }
--   p_details : CSV の明細 [ { bank_code, branch_code, account_type, account_number, holder_kana, amount }, … ]（CSV の並び順のまま。行番号は、この関数が 1 から振る）
--   決まり:
--     ・ログインした給与の担当者（本部・社長・マスター）だけ。サービス用の鍵（ロボット）からは使えない。
--     ・明細の結果は、必ず「不明」で入れる（result を渡されても使わない）。CSV には 1 件ごとの成功・失敗が無いため。→ CSV の金額が合っただけでは、だれも完了にならない。
--     ・CSV の件数・合計が、人が入れた振込件数・振込金額と合わなければ、取り込まない。全銀形式は、ヘッダーの振込指定日（月日）が振込日と合わなければ、取り込まない。
--     ・同じ受付番号をもう一度登録しても、行は増えない（振込日・件数・合計・明細の中身が前回と違えば、取り込まない）。
--     ・取得ジョブが画面の行で確かめた取引（screen_rows）は、この登録では書きかえない。逆に、この登録のあとから取得ジョブの結果が来れば、そちらで書きかえられる。
--       ただし「エラー」の知らせ（状態が failed・partial、またはエラー件数が 1 件以上）だけは、取引の状態と件数に反映する（明細の行は変えない）→ 照合で「確認待ち」になる。
--     ・取得ジョブが銀行の一覧で「エラー」の状態を読んだ取引を、この登録で「正常」などに戻すことはできない。
--     ・だれが・いつ入れたかは、取引の行（entered_by・entered_at）と履歴（bank_csv_registered）に残る。履歴に口座番号・名義・金額は入れない。
create or replace function public.payroll_transfer_bank_csv_register(p_transfer jsonb, p_details jsonb, p_csv_sha256 text, p_csv_format text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); v_sha text := lower(btrim(coalesce(p_csv_sha256, ''))); v_fmt text := btrim(coalesce(p_csv_format, ''));
  v_key text; v_corp uuid; v_keys jsonb; v_assumed boolean := false;
  v_ref text; v_date date; v_exec date; v_cnt integer; v_total numeric; v_okc integer; v_errc integer; v_status text; v_md text;
  v_tr jsonb; v_det jsonb; v_res jsonb; v_tid uuid; v_t bank_bulk_transfers%rowtype; v_bad integer; v_n integer; v_prev_status text; v_prev_source text;
begin
  if v_uid is null or not public.payroll_pay_can() then raise exception '権限がありません（給与の担当者としてログインしてください）'; end if;
  if p_transfer is null or jsonb_typeof(p_transfer) <> 'object' then raise exception '銀行の画面の情報がありません'; end if;
  if p_details is null or jsonb_typeof(p_details) <> 'array' or jsonb_array_length(p_details) = 0 then raise exception 'CSV の明細がありません'; end if;
  if v_sha !~ '^[0-9a-f]{64}$' then raise exception 'CSV の指紋（SHA-256）が必要です'; end if;
  if v_fmt not in ('zengin', 'list') then raise exception 'CSV の形式が不正です（zengin＝全銀形式／list＝振込先一覧形式）'; end if;

  v_ref := nullif(btrim(p_transfer ->> 'bank_ref'), '');
  v_date := (p_transfer ->> 'designated_date')::date;
  v_exec := (p_transfer ->> 'executed_date')::date;
  v_cnt := (p_transfer ->> 'total_count')::integer;
  v_total := (p_transfer ->> 'total_amount')::numeric;
  v_okc := (p_transfer ->> 'ok_count')::integer;
  v_errc := (p_transfer ->> 'error_count')::integer;
  v_status := nullif(btrim(p_transfer ->> 'bank_status'), '');
  if v_ref is null or v_date is null or v_exec is null or v_cnt is null or v_total is null or v_okc is null or v_errc is null or v_status is null then
    raise exception '銀行の画面の情報（受付番号・振込日・実行日・振込件数・振込金額・正常件数・エラー件数・状態）が足りません';
  end if;
  if v_cnt <= 0 or v_total <= 0 or v_okc < 0 or v_errc < 0 or v_okc + v_errc > v_cnt then raise exception '振込件数・正常件数・エラー件数・振込金額の値が不正です'; end if;
  v_md := nullif(btrim(p_transfer ->> 'csv_designated_md'), '');
  if v_fmt = 'zengin' and v_md is null then raise exception '全銀形式の CSV は、ヘッダーの振込指定日（月日）が必要です'; end if;
  if v_md is not null and v_md <> to_char(v_date, 'MMDD') then raise exception 'CSV のヘッダーの振込指定日（月日）が、振込日と合いません。取り込みません'; end if;

  -- CSV の明細の形（口座の項目・名義・1 円以上の整数の金額）と、人が入れた件数・振込金額との一致
  select count(*),
         count(*) filter (where coalesce(btrim(d.value ->> 'account_number'), '') = '' or coalesce(btrim(d.value ->> 'holder_kana'), '') = ''
                             or not (case when (d.value ->> 'amount') ~ '^[0-9]+$' then (d.value ->> 'amount')::numeric > 0 else false end))
    into v_n, v_bad from jsonb_array_elements(p_details) d;
  if v_bad > 0 then raise exception 'CSV の明細に、口座・名義・金額が読めない行があります（% 行）。取り込みません', v_bad; end if;
  if v_n <> v_cnt then raise exception 'CSV の件数（% 件）と、画面の振込件数（% 件）が合いません。取り込みません', v_n, v_cnt; end if;
  if (select sum((d.value ->> 'amount')::numeric) from jsonb_array_elements(p_details) d) <> v_total then
    raise exception 'CSV の金額の合計と、画面の振込金額が合いません。取り込みません';
  end if;

  -- 出金口座の印（無ければ、その法人に 1 つだけ登録されている印を使う）
  v_key := nullif(btrim(p_transfer ->> 'source_account_key'), '');
  if v_key is null then
    v_corp := (p_transfer ->> 'corporation_id')::uuid;
    v_keys := public.payroll_recon_setting() -> 'corps' -> (v_corp::text) -> 'source_account_keys';
    if v_corp is null or v_keys is null or jsonb_typeof(v_keys) <> 'array' or jsonb_array_length(v_keys) <> 1 then
      raise exception '出金口座を決められません（全銀形式の CSV を使うか、この法人の出金口座の印を 1 つだけ設定に登録してください）';
    end if;
    v_key := v_keys ->> 0;
    v_assumed := true;
  end if;

  -- 明細: 結果は必ず「不明」。行番号は CSV の並び順
  select jsonb_agg(jsonb_build_object('line_no', d.ord, 'bank_code', d.value ->> 'bank_code', 'branch_code', d.value ->> 'branch_code', 'account_type', d.value ->> 'account_type',
                                      'account_number', d.value ->> 'account_number', 'holder_kana', d.value ->> 'holder_kana', 'amount', (d.value ->> 'amount')::numeric,
                                      'result', 'unknown') order by d.ord)
    into v_det from jsonb_array_elements(p_details) with ordinality as d(value, ord);
  v_tr := jsonb_strip_nulls(jsonb_build_object(
            'bank', 'paypay', 'source_account_key', v_key, 'bank_ref', v_ref, 'designated_date', v_date, 'executed_date', v_exec, 'total_count', v_cnt, 'total_amount', v_total,
            'fee_total', (p_transfer ->> 'fee_total')::numeric, 'grand_total', (p_transfer ->> 'grand_total')::numeric, 'ok_count', v_okc, 'error_count', v_errc,
            'bank_status', v_status, 'bank_status_raw', nullif(btrim(p_transfer ->> 'bank_status_raw'), ''), 'memo', nullif(btrim(p_transfer ->> 'memo'), ''),
            'detail_source', 'csv_upload', 'csv_sha256', v_sha, 'csv_format', v_fmt));

  select t.bank_status, t.detail_source into v_prev_status, v_prev_source from bank_bulk_transfers t where t.bank = 'paypay' and t.source_account_key = v_key and t.bank_ref = v_ref;
  perform set_config('payroll.csv_register', '1', true);
  v_res := public.bank_bulk_transfer_ingest(v_tr, v_det);
  perform set_config('payroll.csv_register', '', true);
  v_tid := (v_res ->> 'bank_transfer_id')::uuid;
  select * into v_t from bank_bulk_transfers t where t.id = v_tid;

  perform set_config('payroll.recon_ok', '1', true);
  perform public.payroll_recon_log(v_t.batch_id, null, 'bank_csv_registered', null, v_t.bank_status, 'human', null,
                                   jsonb_build_object('bank_transfer_id', v_tid, 'csv_format', v_fmt, 'count', v_cnt, 'new', (v_res ->> 'new')::boolean,
                                                      'source_account_assumed', v_assumed, 'kept_screen_rows', v_t.detail_source = 'screen_rows'));
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'bank_transfer_id', v_tid, 'new', (v_res ->> 'new')::boolean, 'detail_source', v_t.detail_source,
                            'already_verified', v_t.detail_source = 'screen_rows', 'batch_id', v_t.batch_id, 'source_account_assumed', v_assumed,
                            -- 画面の行で確かめた取引に、人が「エラー」の状態を入れた → 取引の状態だけ反映した（確認待ちになる）
                            'failure_reflected', coalesce(v_prev_source = 'screen_rows' and v_t.bank_status is distinct from v_prev_status, false),
                            'batches', v_res -> 'batches');
end $$;
revoke all on function public.payroll_transfer_bank_csv_register(jsonb, jsonb, text, text) from public, anon;
grant execute on function public.payroll_transfer_bank_csv_register(jsonb, jsonb, text, text) to authenticated;

-- ===== G. まとめての手動確認ができるかどうか（内部用。画面用の関数と、下の実行の関数が、同じ判定を使う） =====
--   行の分け方: decided＝すでに決まっている（完了・人が確認済み・失敗・組戻し・銀行の結果が成功）／unmatched＝銀行の明細と結べていない／
--               self＝結べていて結果が「不明」だが、押す本人の行／candidate＝結べていて（口座・名義・金額が 1 対 1 で一致）結果が「不明」の、ほかの人の行
--   止める理由（blockers）: no_bank_transfer／bank_status_not_done／ok_count_not_all／error_count_not_zero／no_csv_evidence／no_candidates
create or replace function public.payroll_recon_manual_bulk_check(p_batch_id uuid, p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_b payroll_transfer_batches%rowtype; v_t bank_bulk_transfers%rowtype; v_blk text[] := array[]::text[];
  v_cand integer := 0; v_self integer := 0; v_unm integer := 0; v_dec integer := 0; v_ev uuid;
begin
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id;
  if v_b.id is null then
    return jsonb_build_object('eligible', false, 'blockers', jsonb_build_array('batch_not_found'), 'candidates', 0, 'skipped_self', 0, 'unmatched', 0, 'decided', 0);
  end if;
  select * into v_t from bank_bulk_transfers t where t.batch_id = v_b.id;
  select count(*) filter (where c.kind = 'candidate'), count(*) filter (where c.kind = 'self'), count(*) filter (where c.kind = 'unmatched'), count(*) filter (where c.kind = 'decided')
    into v_cand, v_self, v_unm, v_dec
    from (select case when l.line_status in ('completed', 'manual_confirmed', 'failed', 'returned') then 'decided'
                      when l.bank_detail_id is null then 'unmatched'
                      when d.result in ('success', 'failed', 'returned') then 'decided'
                      when l.user_id = p_uid then 'self'
                      else 'candidate' end as kind
            from payroll_transfer_batch_lines l left join bank_bulk_transfer_details d on d.id = l.bank_detail_id
           where l.batch_id = v_b.id) c;
  if v_t.id is null then
    v_blk := array_append(v_blk, 'no_bank_transfer');
  else
    if v_t.bank_status <> 'done' then v_blk := array_append(v_blk, 'bank_status_not_done'); end if;
    if v_t.ok_count is distinct from v_t.total_count then v_blk := array_append(v_blk, 'ok_count_not_all'); end if;
    if v_t.error_count is distinct from 0 then v_blk := array_append(v_blk, 'error_count_not_zero'); end if;
    select e.id into v_ev from payroll_transfer_evidence e
     where e.kind in ('detail_csv', 'result_csv', 'manual_upload') and e.sha256 = v_t.csv_sha256
       and e.year_month = v_b.year_month and e.corporation_id = v_b.corporation_id
     order by e.fetched_at limit 1;
    if v_ev is null then v_blk := array_append(v_blk, 'no_csv_evidence'); end if;
  end if;
  if v_cand = 0 then v_blk := array_append(v_blk, 'no_candidates'); end if;
  return jsonb_build_object('eligible', coalesce(array_length(v_blk, 1), 0) = 0, 'blockers', to_jsonb(v_blk), 'candidates', v_cand, 'skipped_self', v_self,
                            'unmatched', v_unm, 'decided', v_dec, 'bank_transfer_id', v_t.id, 'csv_evidence_id', v_ev);
end $$;
revoke all on function public.payroll_recon_manual_bulk_check(uuid, uuid) from public, anon, authenticated;

-- ===== H. まとめての手動確認（人の操作としてだけ動く。スイッチ auto_complete とは無関係） =====
--   条件（1 つでも欠けたら、だれも確認済みにしない）:
--     バッチに銀行の取引が結び付いている／銀行の状態が完了（done）／正常件数＝全件・エラー 0 件／
--     p_evidence_id が、この取引で登録した銀行の CSV の証憑である（同じ対象月・法人・SHA-256）／根拠（p_basis）と理由（p_reason）が入っている
--   確認済みにする行: 銀行の明細と結べている（＝口座・名義・金額が 1 対 1 で一致）・まだ決まっていない・銀行の結果が「不明」・押した本人ではない行。
--   触らない行: 結べていない行（skipped_unmatched）／すでに決まっている行（skipped_decided）／押した本人の行（skipped_self。自分の行は自分で確認できない、は今までどおり）。
--   記録は、1 人ずつの手動確認（payroll_transfer_manual_confirm）と同じ表・同じ形（だれが・いつ・何を見て・なぜ・どの証憑）。
--   全員が決まれば、バッチは「振込完了（手動確認）」（completed_kind = manual・bank_matched_at は空）。自動（auto）・照合済みを人が完了（human）とは別。
--   取り消しは、今までの payroll_transfer_manual_revoke（1 人ずつ・理由つき・記録は残る）。
create or replace function public.payroll_transfer_manual_confirm_matched(p_batch_id uuid, p_basis text, p_reason text, p_evidence_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); v_b payroll_transfer_batches%rowtype; v_t bank_bulk_transfers%rowtype; v_chk jsonb; v_blk jsonb; v_l record; v_conf bigint; v_n integer := 0;
begin
  if v_uid is null or not public.payroll_pay_can() then raise exception '権限がありません（確認者が分かるログインが必要です）'; end if;
  if coalesce(btrim(p_basis), '') = '' then raise exception '何を見て確かめたか（確認の根拠）を入力してください'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '理由を入力してください'; end if;
  if p_evidence_id is null then raise exception '銀行の CSV の証憑が必要です（先に、銀行の CSV を登録してください）'; end if;
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id for update;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;
  select * into v_t from bank_bulk_transfers t where t.batch_id = v_b.id;
  v_chk := public.payroll_recon_manual_bulk_check(v_b.id, v_uid);
  v_blk := v_chk -> 'blockers';
  if v_blk ? 'no_bank_transfer' then raise exception 'このバッチには、まだ銀行の取引が結び付いていません（先に、銀行の CSV を登録して照合してください）'; end if;
  if v_blk ? 'bank_status_not_done' then raise exception '銀行の状態が「振込正常」ではありません。まとめての確認はできません'; end if;
  if (v_blk ? 'ok_count_not_all') or (v_blk ? 'error_count_not_zero') then
    raise exception '銀行の正常件数が全件でない、またはエラー件数が 0 件ではありません。まとめての確認はできません';
  end if;
  if not exists (select 1 from payroll_transfer_evidence e
                  where e.id = p_evidence_id and e.kind in ('detail_csv', 'result_csv', 'manual_upload') and e.sha256 = v_t.csv_sha256
                    and e.year_month = v_b.year_month and e.corporation_id = v_b.corporation_id) then
    raise exception '指定した証憑が、この取引で登録した銀行の CSV ではありません（先に、同じ CSV を証憑として登録してください）';
  end if;

  perform set_config('payroll.recon_ok', '1', true);
  for v_l in
    select l.id, l.user_id
      from payroll_transfer_batch_lines l join bank_bulk_transfer_details d on d.id = l.bank_detail_id
     where l.batch_id = v_b.id and l.line_status not in ('completed', 'manual_confirmed', 'failed', 'returned')
       and d.result not in ('success', 'failed', 'returned') and l.user_id <> v_uid
     order by l.user_id
  loop
    insert into payroll_transfer_manual_confirmations(batch_id, line_id, user_id, action, basis, reason, evidence_id, confirmed_by)
    values (v_b.id, v_l.id, v_l.user_id, 'confirm', btrim(p_basis), btrim(p_reason), p_evidence_id, v_uid)
    returning id into v_conf;
    update payroll_transfer_batch_lines l set manual_confirmation_id = v_conf, updated_at = now() where l.id = v_l.id;
    perform public.payroll_recon_set_line(v_l.id, 'manual_confirmed', 'manual', 'human');
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then
    perform public.payroll_recon_log(v_b.id, null, 'manual_confirmed', v_b.status, v_b.status, 'human', btrim(p_reason),
                                     jsonb_build_object('lines', v_n, 'basis', btrim(p_basis), 'bulk', true, 'evidence_id', p_evidence_id, 'bank_transfer_id', v_t.id));
    perform public.payroll_recon_eval(v_b.id, 'human');
  end if;
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'confirmed', v_n, 'skipped_unmatched', (v_chk ->> 'unmatched')::integer, 'skipped_decided', (v_chk ->> 'decided')::integer,
                            'skipped_self', (v_chk ->> 'skipped_self')::integer,
                            'status', (select b.status from payroll_transfer_batches b where b.id = v_b.id),
                            'completed_kind', (select b.completed_kind from payroll_transfer_batches b where b.id = v_b.id),
                            'status_label', (select public.payroll_transfer_status_label(b.status, b.completed_kind) from payroll_transfer_batches b where b.id = v_b.id));
end $$;
revoke all on function public.payroll_transfer_manual_confirm_matched(uuid, text, text, uuid) from public, anon;
grant execute on function public.payroll_transfer_manual_confirm_matched(uuid, text, text, uuid) to authenticated;

-- ===== I. 画面用の状況（作り直し。今までの戻り値〈_base〉はそのまま、足すだけ。口座番号・名義カナは返さない） =====
--   足すもの
--     各バッチの bank（銀行の取引があるとき）に: bank_ref（受付番号）／executed_date（実行日）／total_amount（振込金額）／fee_total（手数料）／grand_total（合計金額）／
--        ok_count・error_count／detail_source（明細の出どころ）／result_verified_at（照合日時＝画面の行で確かめた日時）／csv_format／memo／
--        entered_by・entered_by_name・entered_at（人が入れたとき）／csv_evidence_id（登録した CSV の証憑）
--     各バッチに: bank_amount_diff（銀行の振込金額 − 予定の合計。銀行の取引が無ければ null）／
--        line_details（行ごと: line_id・user_id・linked・bank_line_no〈銀行の明細番号〉・bank_result・result_basis・mismatch_reason〈結べていない理由〉）／
--        mismatch_counts（結べていない理由ごとの人数）／bank_unmatched（銀行の明細のうち、だれとも結べていないものの件数と行番号）／
--        manual_bulk（まとめての手動確認ができるか: eligible・blockers・candidates・skipped_self・unmatched・decided・csv_evidence_id）
--     全体に: bank_unlinked（振込指定日が同じで、まだどのバッチにも結ばれていない銀行の取引。予定との差を出すため）／
--        source_account_keys（その法人に登録してある出金口座の印）／evidence_bucket（証憑の置き場の名前）
--   Slack 用の関数（payroll_transfer_recon_slack_summary）は、変えていない。
create or replace function public.payroll_transfer_recon_status(p_year_month text, p_corp_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb; v_batches jsonb; v_keys jsonb; v_uid uuid := auth.uid();
begin
  if not public.payroll_pay_can() then raise exception '権限がありません'; end if;
  v := public.payroll_transfer_recon_status_base(p_year_month, p_corp_id);
  v_keys := case when p_corp_id is null then null else public.payroll_recon_setting() -> 'corps' -> (p_corp_id::text) -> 'source_account_keys' end;
  if v_keys is null or jsonb_typeof(v_keys) <> 'array' then v_keys := '[]'::jsonb; end if;

  select coalesce(jsonb_agg(
           e.value || jsonb_build_object(
             'bank', case when x.t_id is not null and jsonb_typeof(e.value -> 'bank') = 'object' then (e.value -> 'bank') || x.bank_extra else e.value -> 'bank' end,
             'bank_amount_diff', x.amount_diff,
             'line_details', (select coalesce(jsonb_agg(jsonb_build_object(
                                        'line_id', l.id, 'user_id', l.user_id, 'linked', l.bank_detail_id is not null, 'bank_line_no', d.line_no, 'bank_result', d.result,
                                        'result_basis', d.result_basis,
                                        'mismatch_reason', case when l.bank_detail_id is null and l.line_status not in ('manual_confirmed', 'completed')
                                                                then coalesce(l.status_reason, 'not_checked_yet') end) order by l.user_id), '[]'::jsonb)
                                from payroll_transfer_batch_lines l left join bank_bulk_transfer_details d on d.id = l.bank_detail_id
                               where l.batch_id = x.b_id),
             'mismatch_counts', (select coalesce(jsonb_object_agg(s.reason, s.n), '{}'::jsonb)
                                   from (select coalesce(l.status_reason, 'not_checked_yet') as reason, count(*) as n
                                           from payroll_transfer_batch_lines l
                                          where l.batch_id = x.b_id and l.bank_detail_id is null and l.line_status not in ('manual_confirmed', 'completed')
                                          group by 1) s),
             'bank_unmatched', (select jsonb_build_object('count', count(*), 'line_nos', coalesce(jsonb_agg(d.line_no order by d.line_no), '[]'::jsonb))
                                  from bank_bulk_transfer_details d
                                 where d.transfer_id = x.t_id and not exists (select 1 from payroll_transfer_batch_lines l where l.bank_detail_id = d.id)),
             'manual_bulk', public.payroll_recon_manual_bulk_check(x.b_id, v_uid))
           order by e.ord), '[]'::jsonb)
    into v_batches
    from jsonb_array_elements(v -> 'batches') with ordinality as e(value, ord)
    left join lateral (
      select b.id as b_id, t.id as t_id, t.total_amount - b.expected_total as amount_diff,
             jsonb_build_object('bank_ref', t.bank_ref, 'executed_date', t.executed_date, 'total_amount', t.total_amount, 'fee_total', t.fee_total, 'grand_total', t.grand_total,
                                'ok_count', t.ok_count, 'error_count', t.error_count, 'detail_source', t.detail_source, 'result_verified_at', t.result_verified_at,
                                'csv_format', t.csv_format, 'memo', t.memo, 'entered_by', t.entered_by, 'entered_by_name', (select u.name from users u where u.id = t.entered_by),
                                'entered_at', t.entered_at,
                                'csv_evidence_id', (select e2.id from payroll_transfer_evidence e2
                                                     where e2.kind in ('detail_csv', 'result_csv', 'manual_upload') and e2.sha256 = t.csv_sha256
                                                       and e2.year_month = b.year_month and e2.corporation_id = b.corporation_id
                                                     order by e2.fetched_at limit 1)) as bank_extra
        from payroll_transfer_batches b left join bank_bulk_transfers t on t.batch_id = b.id
       where b.id = (e.value ->> 'batch_id')::uuid
    ) x on true;

  return v || jsonb_build_object(
    'batches', v_batches,
    'bank_unlinked', (select coalesce(jsonb_agg(jsonb_build_object(
                                 'bank_transfer_id', t.id, 'bank_ref', t.bank_ref, 'designated_date', t.designated_date, 'executed_date', t.executed_date,
                                 'total_count', t.total_count, 'total_amount', t.total_amount, 'fee_total', t.fee_total, 'bank_status', t.bank_status, 'bank_status_raw', t.bank_status_raw,
                                 'detail_source', t.detail_source, 'entered_at', t.entered_at, 'source_account_known', coalesce(v_keys ? t.source_account_key, false))
                               order by t.designated_date, t.bank_ref), '[]'::jsonb)
                        from bank_bulk_transfers t
                       where t.batch_id is null
                         and t.designated_date in (select b.scheduled_date from payroll_transfer_batches b
                                                    where b.year_month = p_year_month and (p_corp_id is null or b.corporation_id = p_corp_id))),
    'source_account_keys', v_keys,
    'evidence_bucket', 'payroll-transfer-evidence');
end $$;
revoke all on function public.payroll_transfer_recon_status(text, uuid) from public, anon;
grant execute on function public.payroll_transfer_recon_status(text, uuid) to authenticated;
