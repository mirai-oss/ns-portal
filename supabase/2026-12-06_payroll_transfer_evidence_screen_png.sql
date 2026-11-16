-- 振込照合: 銀行の画面の写真（PNG）を正式な証憑に登録できるようにする／従業員ごとの照合の見える化（読むだけ）（2026-11-16・社長承認済みの開発）
--
-- 足すもの
--   A. 証憑の種類に 'screen_png'（取得ジョブが銀行の画面から自動で撮った写真）。この種類は、サービス用の鍵（取得ジョブ）からしか登録できない
--      ＝人が入れた説明用の画像・サンプルとは、種類と出どころ（origin）で区別がつく。対象の振込（bank_transfer_id）とバッチが必須。
--   B. 証憑の表に列 origin（'bank_job'＝取得ジョブが自動で取った／'human_upload'＝人が入れた／null＝この変更より前に入れたもの）。既存の行は書きかえない。
--   C. 証憑の置き場（payroll-transfer-evidence）で、PNG も置けるようにする（非公開のまま・20MB のまま）。
--   D. payroll_transfer_evidence_add の作り直し（引数は同じ）: 'screen_png' の条件と origin の記録だけを足した。それ以外は元（2026-11-24）のまま。
--   E. payroll_transfer_line_recon_view(バッチ): 従業員ごとの「銀行の結果」と「従業員との照合」を分けて返す。★読むだけ（何も書かない）。
--      氏名・口座・金額は返さない（従業員の id と状態だけ）。
-- 変えないもの: bank_read_enabled・自動照合・振込済みの自動更新のスイッチ（どれも OFF のまま）。既存の関数・表の列・トリガー。
-- 戻し方: 2026-12-06_payroll_transfer_evidence_screen_png_rollback.sql

-- ===== A. 種類 =====
do $$
declare v_c record;
begin
  for v_c in select c.conname from pg_constraint c
              where c.conrelid = 'public.payroll_transfer_evidence'::regclass and c.contype = 'c' and pg_get_constraintdef(c.oid) like '%detail_pdf%'
  loop
    execute format('alter table public.payroll_transfer_evidence drop constraint %I', v_c.conname);
  end loop;
end $$;
alter table public.payroll_transfer_evidence add constraint payroll_transfer_evidence_kind_check
  check (kind in ('detail_pdf', 'result_pdf', 'detail_csv', 'result_csv', 'manual_upload', 'unavailable', 'screen_png'));

-- ===== B. 出どころ =====
alter table public.payroll_transfer_evidence add column if not exists origin text;
alter table public.payroll_transfer_evidence drop constraint if exists payroll_transfer_evidence_origin_check;
alter table public.payroll_transfer_evidence add constraint payroll_transfer_evidence_origin_check check (origin is null or origin in ('bank_job', 'human_upload'));
comment on column public.payroll_transfer_evidence.origin is 'bank_job＝取得ジョブが銀行の画面から自動で取った／human_upload＝人が入れた／null＝この列を足す前に入れたもの（人が入れたもの）';

-- ===== C. 置き場 =====
update storage.buckets set allowed_mime_types = array['text/csv', 'application/pdf', 'image/png'] where id = 'payroll-transfer-evidence';

-- ===== D. 証憑の登録（作り直し。元は 2026-11-24） =====
create or replace function public.payroll_transfer_evidence_add(p_year_month text, p_corp_id uuid, p_kind text, p_storage_bucket text, p_storage_path text, p_sha256 text,
                                                                p_size_bytes bigint, p_mime text, p_fetched_at timestamptz, p_source text, p_fetched_by text default null,
                                                                p_batch_id uuid default null, p_bank_transfer_id uuid default null, p_bank_status text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_sha text := lower(btrim(coalesce(p_sha256, ''))); v_id uuid; v_by text := coalesce(nullif(btrim(p_fetched_by), ''), auth.uid()::text);
        v_origin text := case when auth.uid() is null then 'bank_job' else 'human_upload' end;
begin
  if not public.payroll_recon_can() then raise exception '権限がありません'; end if;
  if p_kind is null or p_kind not in ('detail_pdf', 'result_pdf', 'detail_csv', 'result_csv', 'manual_upload', 'screen_png') then raise exception '証憑の種類が不正です'; end if;
  if v_sha !~ '^[0-9a-f]{64}$' then raise exception 'SHA-256 が不正です'; end if;
  if coalesce(btrim(p_storage_bucket), '') = '' or coalesce(btrim(p_storage_path), '') = '' then raise exception '保存先がありません'; end if;
  if p_fetched_at is null or coalesce(btrim(p_source), '') = '' or v_by is null then raise exception '取得日時・取得元・取得した人（またはロボットの名前）が必要です'; end if;
  -- 銀行の画面の写真は、取得ジョブ（サービス用の鍵）からだけ。人が入れた説明用の画像を、画面の写真として正式に登録することはできない
  if p_kind = 'screen_png' then
    if not public.payroll_recon_is_service() then raise exception '銀行の画面の写真（screen_png）は、取得ジョブからだけ登録できます'; end if;
    if p_batch_id is null or p_bank_transfer_id is null then raise exception '銀行の画面の写真には、対象の振込（バッチ・銀行取引）が必要です'; end if;
    if p_mime is distinct from 'image/png' or lower(p_storage_path) not like '%.png' then raise exception '銀行の画面の写真は PNG だけです'; end if;
    if not exists (select 1 from bank_bulk_transfers t where t.id = p_bank_transfer_id and t.batch_id = p_batch_id) then
      raise exception '対象の振込が、そのバッチに結ばれていません。登録しません';
    end if;
    if not exists (select 1 from payroll_transfer_batches b where b.id = p_batch_id and b.year_month = p_year_month and b.corporation_id = p_corp_id) then
      raise exception 'バッチの対象月・法人が、指定と違います。登録しません';
    end if;
  end if;

  select e.id into v_id from payroll_transfer_evidence e
   where e.year_month = p_year_month and e.corporation_id = p_corp_id and e.kind = p_kind and e.sha256 = v_sha;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'duplicate', true, 'evidence_id', v_id);
  end if;
  if exists (select 1 from payroll_transfer_evidence e where e.storage_bucket = p_storage_bucket and e.storage_path = p_storage_path) then
    raise exception '同じ保存先が、すでに別の証憑で使われています（上書きはしません）';
  end if;

  perform set_config('payroll.recon_ok', '1', true);
  insert into payroll_transfer_evidence(year_month, corporation_id, batch_id, bank_transfer_id, kind, storage_bucket, storage_path, sha256, size_bytes, mime,
                                        fetched_at, source, fetched_by, bank_status_at_fetch, origin)
  values (p_year_month, p_corp_id, p_batch_id, p_bank_transfer_id, p_kind, p_storage_bucket, p_storage_path, v_sha, p_size_bytes, p_mime,
          p_fetched_at, btrim(p_source), v_by, p_bank_status, v_origin)
  returning id into v_id;
  perform public.payroll_recon_log(p_batch_id, null, 'evidence_saved', null, null, case when auth.uid() is null then 'auto_bank' else 'human' end, null,
                                   jsonb_build_object('evidence_id', v_id, 'kind', p_kind, 'year_month', p_year_month, 'origin', v_origin));
  perform set_config('payroll.recon_ok', '', true);
  return jsonb_build_object('ok', true, 'duplicate', false, 'evidence_id', v_id);
end $$;
revoke all on function public.payroll_transfer_evidence_add(text, uuid, text, text, text, text, bigint, text, timestamptz, text, text, uuid, uuid, text) from public, anon;
grant execute on function public.payroll_transfer_evidence_add(text, uuid, text, text, text, text, bigint, text, timestamptz, text, text, uuid, uuid, text) to authenticated, service_role;

-- ===== E. 従業員ごとの照合の見える化（読むだけ） =====
--   銀行の結果（bank_state）と、従業員との照合（match_state）を、別々に返す。
--     bank_state : success＝銀行が「正常」（画面の行で確かめた結果だけ）／failed＝失敗・組戻し／pending＝まだ分からない（不明・処理中・受付・画面の行で確かめていない）／none＝銀行の明細と結べていない
--     match_state: matched＝口座の鍵・名義カナ・金額が 1 対 1 で一致／mismatch＝一致しない（reason に理由）／pending＝判断できない（銀行のデータがまだ無い・同じ口座の人が 2 人いる）
--     verdict    : ready＝銀行が正常 かつ 照合が成功（それ以外は、自動では「振込済み」の候補にしない）／bank_failed／mismatch／pending
create or replace function public.payroll_transfer_line_recon_view(p_batch_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_b payroll_transfer_batches%rowtype; v_t bank_bulk_transfers%rowtype; v_lines jsonb; v_counts jsonb;
begin
  if not public.payroll_recon_can() then raise exception '権限がありません'; end if;
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;
  select * into v_t from bank_bulk_transfers t where t.batch_id = v_b.id;

  with c as (
  select x.id, x.user_id, x.line_status,
         case when x.d_id is null then 'none'
              when x.result = 'success' and x.result_basis = 'screen_row' then 'success'
              when x.result in ('failed', 'returned') then 'failed'
              else 'pending' end as bank_state,
         case when x.d_id is not null and x.d_acct is not distinct from x.acct_key and x.d_kana is not distinct from x.kana_norm and x.d_amount = x.amount then 'matched'
              when x.d_id is not null then 'mismatch'
              when v_t.id is null or x.n_details = 0 then 'pending'
              when x.same_acct > 1 then 'pending'
              else 'mismatch' end as match_state,
         case when x.d_id is not null and not (x.d_acct is not distinct from x.acct_key and x.d_kana is not distinct from x.kana_norm and x.d_amount = x.amount) then 'link_inconsistent'
              when x.d_id is not null then null
              when v_t.id is null then 'bank_transfer_not_linked'
              when x.n_details = 0 then 'bank_details_missing'
              when x.same_acct > 1 then 'same_account_two_people'
              when x.has_acct_kana then 'amount_mismatch'
              when x.has_acct then 'kana_mismatch'
              when x.has_kana_amt then 'account_mismatch'
              else 'not_found_in_bank' end as reason
    from (
      select l.id, l.user_id, l.line_status, l.acct_key, l.kana_norm, l.amount,
             d.id as d_id, d.result, d.result_basis, d.acct_key as d_acct, d.kana_norm as d_kana, d.amount as d_amount,
             (select count(*) from payroll_transfer_batch_lines l2 where l2.batch_id = l.batch_id and l2.acct_key = l.acct_key) as same_acct,
             (select count(*) from bank_bulk_transfer_details z where z.transfer_id = v_t.id) as n_details,
             exists (select 1 from bank_bulk_transfer_details z where z.transfer_id = v_t.id and z.acct_key = l.acct_key and z.kana_norm = l.kana_norm) as has_acct_kana,
             exists (select 1 from bank_bulk_transfer_details z where z.transfer_id = v_t.id and z.acct_key = l.acct_key) as has_acct,
             exists (select 1 from bank_bulk_transfer_details z where z.transfer_id = v_t.id and z.kana_norm = l.kana_norm and z.amount = l.amount and z.acct_key is not null) as has_kana_amt
        from payroll_transfer_batch_lines l
        left join bank_bulk_transfer_details d on d.id = l.bank_detail_id
       where l.batch_id = v_b.id
    ) x
  ), v as (
    select c.*, case when c.bank_state = 'failed' then 'bank_failed'
                     when c.match_state = 'mismatch' then 'mismatch'
                     when c.bank_state = 'success' and c.match_state = 'matched' then 'ready'
                     else 'pending' end as verdict
      from c
  )
  select coalesce(jsonb_agg(jsonb_build_object('line_id', r.id, 'user_id', r.user_id, 'line_status', r.line_status, 'bank_state', r.bank_state,
                                               'match_state', r.match_state, 'reason', r.reason, 'verdict', r.verdict) order by r.user_id), '[]'::jsonb),
         jsonb_build_object('people', count(*), 'ready', count(*) filter (where r.verdict = 'ready'), 'bank_failed', count(*) filter (where r.verdict = 'bank_failed'),
                            'mismatch', count(*) filter (where r.verdict = 'mismatch'), 'pending', count(*) filter (where r.verdict = 'pending'),
                            'bank_success', count(*) filter (where r.bank_state = 'success'), 'matched', count(*) filter (where r.match_state = 'matched'))
    into v_lines, v_counts from v r;
  return jsonb_build_object('batch_id', v_b.id, 'bank_transfer_id', v_t.id, 'detail_source', v_t.detail_source, 'counts', v_counts, 'lines', v_lines);
end $$;
revoke all on function public.payroll_transfer_line_recon_view(uuid) from public, anon;
grant execute on function public.payroll_transfer_line_recon_view(uuid) to authenticated, service_role;
