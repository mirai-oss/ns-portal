-- 段階4（2026-11-28_bank_ledger_stage4.sql）の取り消し。状態: 下書き（未適用）
-- 照合の記録の表（bank_reconcile_runs・bank_reconcile_mismatches）が空のときだけ。bank_legacy_plan は段階3の定義に戻す。
-- 差異の状態 resolved が使われている行があると、制約を元に戻せないので止まる。
do $$
declare n bigint := 0; r bigint := 0;
begin
  if to_regclass('public.bank_reconcile_runs') is not null then select count(*) into n from public.bank_reconcile_runs; end if;
  if to_regclass('public.bank_reconcile_mismatches') is not null then select count(*) into r from public.bank_reconcile_mismatches; end if;
  if n + r > 0 then raise exception '照合の記録に % 件のデータが入っています。取り消しを中止しました', n + r; end if;
  if exists (select 1 from public.bank_diff_items where status = 'resolved') then raise exception '解消済み（resolved）の差異があるため、状態の制約を戻せません。取り消しを中止しました'; end if;
end $$;
drop function if exists public.bank_reconcile_report(integer);
drop function if exists public.bank_reconcile_run(uuid, uuid, date);
drop table if exists public.bank_reconcile_mismatches;
drop table if exists public.bank_reconcile_runs;
drop function if exists public.bank_reconcile_guard();
alter table public.bank_diff_items drop constraint if exists bank_diff_items_status_check;
alter table public.bank_diff_items add constraint bank_diff_items_status_check check (status in ('open', 'held', 'approved', 'corrected', 'rejected'));
alter table public.bank_diff_items drop column if exists resolved_at;
alter table public.bank_diff_items drop column if exists resolved_batch;
-- 段階3の bank_legacy_plan に戻す
create or replace function public.bank_legacy_plan(p_batch uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_paired int := 0; v_mig int := 0; v_adj int := 0; v_unres int := 0; v_inwin int := 0; v_bank_only int := 0; v_amb int := 0; v_ph int := 0; n int;
begin
  perform public.bank_assert_service();
  if not exists (select 1 from public.bank_legacy_batches where id = p_batch) then raise exception 'バッチが見つかりません'; end if;
  -- 対象の旧行（まだ対応づけていない行だけ。同一性は 内容ハッシュ#出現番号）
  drop table if exists _bl_l; drop table if exists _bl_t; drop table if exists _bl_p;
  create temporary table _bl_l on commit drop as
    select r.id, r.content_hash || '#' || r.ordinal as lkey, r.kind, r.store_id, r.txn_date, r.amount, r.row_no, r.description,
           case when r.token ~ '^\d{1,2}:\d{2}' then lpad(split_part(r.token, ':', 1), 2, '0') || ':' || left(split_part(r.token, ':', 2), 2) end as hhmm
      from public.bank_legacy_rows r
     where r.batch_id = p_batch and not exists (select 1 from public.bank_legacy_links k where k.legacy_key = r.content_hash || '#' || r.ordinal);
  -- A. 店舗が決まらない行・手動の調整行
  insert into public.bank_legacy_links (legacy_key, first_batch_id, kind, basis)
    select lkey, p_batch, 'unresolved', 'no_store' from _bl_l where store_id is null on conflict (legacy_key) do nothing;
  get diagnostics v_unres = row_count;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, detail)
    select p_batch, 'unresolved|' || lkey, 'unresolved_store', null, txn_date, amount, description, array[lkey], jsonb_build_object('row_no', row_no)
      from _bl_l where store_id is null on conflict (sig) do nothing;
  insert into public.bank_legacy_links (legacy_key, first_batch_id, kind, basis)
    select lkey, p_batch, 'adjustment', 'manual_adjustment' from _bl_l where store_id is not null and kind = 'adjustment' on conflict (legacy_key) do nothing;
  get diagnostics v_adj = row_count;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, detail)
    select p_batch, 'adjustment|' || lkey, 'manual_adjustment', store_id, txn_date, amount, description, array[lkey],
           -- 個別確認の対象: 高額（300 万円以上）・マイナス・ゼロ（金額が 0 以下）。複数に当てはまる行も 1 件として数える（review_class は 1 つ）。
           -- numbers_preserved: 移行で数字は維持される（自動）。この差異の「承認」は、調整内容が正当かどうかの確認で、数字の維持とは別。
           jsonb_build_object('row_no', row_no, 'high', abs(amount) >= 3000000, 'negative', amount < 0, 'zero', amount = 0,
                              'review_class', case when amount <= 0 or abs(amount) >= 3000000 then 'individual' else 'bulk' end, 'numbers_preserved', true)
      from _bl_l where store_id is not null and kind = 'adjustment' on conflict (sig) do nothing;
  -- B. 銀行CSV由来の明細（まだ旧行と結んでいないもの）
  create temporary table _bl_t on commit drop as
    select t.id, t.store_id, t.txn_date, t.deposit_amount as amount, t.txn_time, t.dedupe_key, t.match_status,
           to_char(t.txn_time, 'HH24:MI') as hhmm
      from public.bank_transactions t
     where t.source_kind in ('playwright', 'manual_csv') and t.counts_as_sales_deposit and t.deposit_amount > 0 and t.store_id is not null
       and t.match_status in ('verified', 'held')
       and not exists (select 1 from public.bank_legacy_links k where k.kind = 'paired' and k.transaction_id = t.id);
  -- C. 対応づけ: ①時:分が一致するもの同士 ②残りを、その日その金額の中で順番に
  create temporary table _bl_p (lid uuid, lkey text, tid uuid, basis text, confidence text) on commit drop;
  insert into _bl_p
    select l.id, l.lkey, t.id, 'time', 'auto'
      from (select *, row_number() over (partition by store_id, txn_date, amount, hhmm order by row_no) rn from _bl_l where kind = 'atm' and store_id is not null and hhmm is not null) l
      join (select *, row_number() over (partition by store_id, txn_date, amount, hhmm order by txn_time, dedupe_key) rn from _bl_t where hhmm is not null) t
        on l.store_id = t.store_id and l.txn_date = t.txn_date and l.amount = t.amount and l.hhmm = t.hhmm and l.rn = t.rn;
  insert into _bl_p
    select l.id, l.lkey, t.id, case when g.nl = 1 and g.nt = 1 then 'single' else 'order' end, case when g.nl = 1 and g.nt = 1 then 'auto' else 'proposed' end
      from (select *, row_number() over (partition by store_id, txn_date, amount order by row_no) rn from _bl_l l0
             where kind = 'atm' and store_id is not null and not exists (select 1 from _bl_p p where p.lid = l0.id)) l
      join (select *, row_number() over (partition by store_id, txn_date, amount order by txn_time nulls last, dedupe_key) rn from _bl_t t0
             where not exists (select 1 from _bl_p p where p.tid = t0.id)) t
        on l.store_id = t.store_id and l.txn_date = t.txn_date and l.amount = t.amount and l.rn = t.rn
      join (select store_id, txn_date, amount, count(*) filter (where src = 'l') nl, count(*) filter (where src = 't') nt
              from (select store_id, txn_date, amount, 'l' src from _bl_l where kind = 'atm' and store_id is not null
                    union all select store_id, txn_date, amount, 't' from _bl_t) u group by 1, 2, 3) g
        on g.store_id = l.store_id and g.txn_date = l.txn_date and g.amount = l.amount;
  insert into public.bank_legacy_links (legacy_key, first_batch_id, kind, transaction_id, basis, confidence)
    select lkey, p_batch, 'paired', tid, basis, confidence from _bl_p on conflict (legacy_key) do nothing;
  get diagnostics v_paired = row_count;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, transaction_ids, detail)
    select p_batch, 'ambiguous|' || p.lkey, 'ambiguous_pair', l.store_id, l.txn_date, l.amount, l.description, array[p.lkey], array[p.tid], jsonb_build_object('basis', p.basis)
      from _bl_p p join _bl_l l on l.id = p.lid where p.confidence = 'proposed' on conflict (sig) do nothing;
  get diagnostics v_amb = row_count;
  -- 旧シートに対応があるのに、銀行側の明細が保留のままのもの（例: 店舗名の別表記で「旧に無い」と見えていた入金）。保留の行は集計に入らないので、旧と数字がずれる → 人が解くまで差異として残す
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, transaction_ids, status, detail)
    select p_batch, 'pairedheld|' || p.tid, 'paired_held', l.store_id, l.txn_date, l.amount, l.description, array[p.lkey], array[p.tid], 'held',
           jsonb_build_object('hold_reason', tx.hold_reason, 'basis', p.basis)
      from _bl_p p join _bl_l l on l.id = p.lid join public.bank_transactions tx on tx.id = p.tid where tx.match_status = 'held' on conflict (sig) do nothing;
  get diagnostics v_ph = row_count;
  -- D. 対応が無い旧行 → 移行（旧のみ）。銀行CSVの期間の中なら「旧のみ（要確認）」の差異にする
  insert into public.bank_legacy_links (legacy_key, first_batch_id, kind, basis)
    select l.lkey, p_batch, 'migrated',
           case when cov.d0 is null then 'no_bank_account' when l.txn_date < cov.d0 then 'before_csv_window' else 'in_window_unmatched' end
      from _bl_l l left join (select store_id, min(txn_date) d0 from public.bank_transactions where source_kind in ('playwright', 'manual_csv') and store_id is not null group by 1) cov on cov.store_id = l.store_id
     where l.kind = 'atm' and l.store_id is not null and not exists (select 1 from _bl_p p where p.lid = l.id)
    on conflict (legacy_key) do nothing;
  get diagnostics v_mig = row_count;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, detail)
    select p_batch, 'inwin|' || l.lkey, 'legacy_only_in_window', l.store_id, l.txn_date, l.amount, l.description, array[l.lkey], jsonb_build_object('row_no', l.row_no)
      from _bl_l l join public.bank_legacy_links k on k.legacy_key = l.lkey and k.basis = 'in_window_unmatched' on conflict (sig) do nothing;
  get diagnostics v_inwin = row_count;
  -- E. 旧に対応が無い銀行の明細 → 差異（保留中の行は held、それ以外は open。当日分は時刻差の可能性を detail に残す）
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, transaction_ids, status, detail)
    select p_batch, 'bankonly|' || t.id, 'bank_only', t.store_id, t.txn_date, t.amount, tx.description, array[t.id],
           case when t.match_status = 'held' then 'held' else 'open' end,
           jsonb_build_object('match_status', t.match_status, 'hold_reason', tx.hold_reason, 'timing', t.txn_date >= (now() at time zone 'Asia/Tokyo')::date)
      from _bl_t t join public.bank_transactions tx on tx.id = t.id
     where not exists (select 1 from _bl_p p where p.tid = t.id) on conflict (sig) do nothing;
  get diagnostics v_bank_only = row_count;
  return jsonb_build_object('paired', v_paired, 'migrated', v_mig, 'adjustments', v_adj, 'unresolved', v_unres,
                            'ambiguous_pairs', v_amb, 'paired_held', v_ph, 'legacy_only_in_window', v_inwin, 'bank_only', v_bank_only);
end $$;

revoke all on function public.bank_legacy_plan(uuid) from public, anon, authenticated;
grant execute on function public.bank_legacy_plan(uuid) to service_role;
