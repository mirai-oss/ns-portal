-- 銀行入金明細の正本（Supabase）— 段階4: 並行稼働の毎日の照合（旧シート ⇔ 正本）の仕組み
-- 作成: 2026-11-28　状態: **下書き（未適用）**。本番への適用は、別途承認。
-- 前提: 段階1〜3 が適用済み。段階1〜3のファイルは編集しない（変更はこの新しいファイルで）。
--
-- 【この SQL がやること】
--   ① 差異の状態に「resolved（自動で解消）」を足す。
--   ② 毎日の照合の記録（bank_reconcile_runs＝1 回の実行の結果／bank_reconcile_mismatches＝店舗×日付の不一致。原因・解消の状況つき）の表を 2 つ足す。
--   ③ bank_reconcile_run（毎日の照合）と bank_reconcile_report（14 日間の経過）の関数を足す。
--   ④ bank_legacy_plan を置き換える（変更点は 1 つだけ: 銀行CSVの期間内で、まだ銀行の明細と対応しない旧行は、移行せず差異にだけ出す。理由は関数内のコメント）。
-- 【この SQL がやらないこと】既存データの変更（関数と表を足すだけ）、画面・GAS・BigQuery・旧シートの変更、自動実行の登録。
-- 【既存への影響】段階3で移行済みのデータは変わらない（旧のみ 4,587 行の移行は「銀行CSVの期間より前」「口座未登録」だけで、期間内の旧のみは 0 件だったため）。
-- 【ロールバック】2026-11-28_bank_ledger_stage4_ROLLBACK.sql（新しい表が空のときだけ。bank_legacy_plan は段階3の定義に戻す）。
-- 毎日の照合の流れ: 旧シートを取り出して保存（bank_legacy_load）→ bank_reconcile_run（前回との変化の検出→取引単位の対応づけ→不一致の記録→解消の判定）。

-- ① 差異の状態に resolved を足す
do $$
begin
  alter table public.bank_diff_items add column if not exists resolved_at timestamptz;
  alter table public.bank_diff_items add column if not exists resolved_batch uuid;
  alter table public.bank_diff_items drop constraint if exists bank_diff_items_status_check;
  alter table public.bank_diff_items add constraint bank_diff_items_status_check check (status in ('open', 'held', 'approved', 'corrected', 'rejected', 'resolved'));
end $$;

-- ② 毎日の照合の記録
create table if not exists public.bank_reconcile_runs (
  id               uuid primary key default gen_random_uuid(),
  run_date         date not null,                          -- 日本時間の実行日
  batch_id         uuid not null references public.bank_legacy_batches (id),
  prev_batch_id    uuid references public.bank_legacy_batches (id),
  legacy_rows      integer not null,
  ledger_csv_rows  integer not null,                       -- 正本の銀行CSV由来の明細の数
  paired_total     integer not null,                       -- 取引単位で 1 対 1 に対応づいている数（旧行 ⇔ 銀行の明細）
  unpaired_legacy  integer not null,                       -- 銀行の期間内で、まだ対応しない旧行（差異）
  unpaired_bank    integer not null,                       -- 旧に対応しない銀行の明細（差異）
  changes          jsonb not null default '{}'::jsonb,     -- 前回からの変化（追加・削除・修正の候補・並べ替え）
  store_dates      integer not null,                       -- 比較した店舗×日付の数
  mismatches_open  integer not null,                       -- 不一致（店舗×日付）の数
  mismatches_unexplained integer not null,                 -- うち、原因が分からないもの
  mismatches_timing integer not null,                      -- うち、取込のタイミング差（当日・前日分）
  mismatches_new   integer not null, mismatches_resolved integer not null,
  legacy_total     numeric not null, ledger_total numeric not null,
  status           text not null check (status in ('ok', 'mismatch')),   -- ok = タイミング差を除いて不一致 0
  created_at       timestamptz not null default now()
);
create unique index if not exists bank_reconcile_runs_batch_uniq on public.bank_reconcile_runs (batch_id);
create table if not exists public.bank_reconcile_mismatches (
  id             uuid primary key default gen_random_uuid(),
  store_id       uuid not null references public.stores (id),
  txn_date       date not null,
  first_run_id   uuid not null references public.bank_reconcile_runs (id),
  last_run_id    uuid not null references public.bank_reconcile_runs (id),
  legacy_count integer not null, ledger_count integer not null, legacy_amount numeric not null, ledger_amount numeric not null,
  cause          text not null,                            -- 原因（差異の種類。分からなければ unexplained）
  is_timing      boolean not null default false,           -- 取込のタイミング差（当日・前日）
  days_open      integer not null default 0,
  status         text not null default 'open' check (status in ('open', 'auto_resolved')),
  resolved_run_id uuid references public.bank_reconcile_runs (id),
  resolved_at    timestamptz,
  created_at     timestamptz not null default now()
);
create unique index if not exists bank_reconcile_mismatch_open_uniq on public.bank_reconcile_mismatches (store_id, txn_date) where status = 'open';
alter table public.bank_reconcile_runs enable row level security;
alter table public.bank_reconcile_mismatches enable row level security;
drop policy if exists bank_reconcile_runs_read on public.bank_reconcile_runs;
create policy bank_reconcile_runs_read on public.bank_reconcile_runs for select to authenticated using (public.bank_ledger_admin());
drop policy if exists bank_reconcile_mismatches_read on public.bank_reconcile_mismatches;
create policy bank_reconcile_mismatches_read on public.bank_reconcile_mismatches for select to authenticated using (public.bank_ledger_admin());
revoke all on public.bank_reconcile_runs, public.bank_reconcile_mismatches from anon, authenticated;
grant select on public.bank_reconcile_runs, public.bank_reconcile_mismatches to authenticated;
-- 実行の記録は更新・削除できない。不一致の記録は削除できない（状態・最終実行などだけ変わる）
drop trigger if exists bank_reconcile_runs_append_only on public.bank_reconcile_runs;
create trigger bank_reconcile_runs_append_only before update or delete on public.bank_reconcile_runs for each row execute function public.bank_append_only();
create or replace function public.bank_reconcile_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then raise exception '照合の不一致の記録は削除できません'; end if;
  if new.store_id is distinct from old.store_id or new.txn_date is distinct from old.txn_date or new.first_run_id is distinct from old.first_run_id then raise exception '不一致の対象は変更できません'; end if;
  return new;
end $$;
revoke all on function public.bank_reconcile_guard() from public, anon, authenticated;
drop trigger if exists bank_reconcile_mismatches_guard_trg on public.bank_reconcile_mismatches;
create trigger bank_reconcile_mismatches_guard_trg before update or delete on public.bank_reconcile_mismatches for each row execute function public.bank_reconcile_guard();

-- ④ 取引単位の対応づけ（段階3の定義から、旧行の「期間内で対応なし」の扱いだけ変更）
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
  -- D. 対応が無い旧行。銀行CSVの期間より前・銀行口座が無い店舗は「旧のみ」として移行する（数字を保つ）。
  --    【段階4で変更】銀行CSVの期間の中で、まだ銀行の明細と対応しない旧行は、移行せず「旧のみ（要確認）」の差異にだけ出す（リンクを作らない）。
  --    並行稼働中は、銀行側の取込が遅れただけのことがあり、先に移行すると、あとで銀行の明細が入ったときに二重に数えてしまうため。
  --    次の取り出しで銀行の明細と対応が取れたら、自動で対応づけ、差異を解消済みにする。
  insert into public.bank_legacy_links (legacy_key, first_batch_id, kind, basis)
    select l.lkey, p_batch, 'migrated', case when cov.d0 is null then 'no_bank_account' else 'before_csv_window' end
      from _bl_l l left join (select store_id, min(txn_date) d0 from public.bank_transactions where source_kind in ('playwright', 'manual_csv') and store_id is not null group by 1) cov on cov.store_id = l.store_id
     where l.kind = 'atm' and l.store_id is not null and not exists (select 1 from _bl_p p where p.lid = l.id)
       and (cov.d0 is null or l.txn_date < cov.d0)
    on conflict (legacy_key) do nothing;
  get diagnostics v_mig = row_count;
  insert into public.bank_diff_items (batch_id, sig, kind, store_id, txn_date, amount, description, legacy_keys, detail)
    select p_batch, 'inwin|' || l.lkey, 'legacy_only_in_window', l.store_id, l.txn_date, l.amount, l.description, array[l.lkey],
           jsonb_build_object('row_no', l.row_no, 'timing', l.txn_date >= (now() at time zone 'Asia/Tokyo')::date - 1)
      from _bl_l l join (select store_id, min(txn_date) d0 from public.bank_transactions where source_kind in ('playwright', 'manual_csv') and store_id is not null group by 1) cov on cov.store_id = l.store_id
     where l.kind = 'atm' and l.store_id is not null and l.txn_date >= cov.d0 and not exists (select 1 from _bl_p p where p.lid = l.id)
    on conflict (sig) do nothing;
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


-- ③ 毎日の照合。旧シートの取り出し（bank_legacy_load 済みのバッチ）を受け取り、前回との変化の検出 → 取引単位の対応づけ → 旧のみ・調整の移行 → 備考 →
--    自動で解消できる差異の解消 → 店舗×日付の不一致を記録（原因・解消の状況つき）。同じバッチは 1 回しか照合できない。
--    不一致のうち「取込のタイミング差」（当日・前日分）は、不一致として数えるが、14 日間の合格判定からは外す。
create or replace function public.bank_reconcile_run(p_batch uuid, p_prev uuid default null, p_run_date date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_date date := coalesce(p_run_date, (now() at time zone 'Asia/Tokyo')::date);
  v_chg jsonb := '{}'::jsonb; v_pl jsonb; v_mg jsonb; v_nm jsonb; v_run uuid;
  v_open int; v_unexp int; v_timing int; v_new int; v_resolved int; v_status text;
  v_lrows int; v_csv int; v_paired int; v_ul int; v_ub int; v_sd int; v_lt numeric; v_dt numeric;
begin
  perform public.bank_assert_service();
  if not exists (select 1 from public.bank_legacy_batches where id = p_batch) then raise exception '取り出し（バッチ）が見つかりません'; end if;
  if exists (select 1 from public.bank_reconcile_runs where batch_id = p_batch) then raise exception 'この取り出しは、すでに照合済みです'; end if;
  if p_prev is not null and p_prev <> p_batch then v_chg := public.bank_legacy_changes(p_batch, p_prev); end if;
  v_pl := public.bank_legacy_plan(p_batch); v_mg := public.bank_legacy_migrate(p_batch); v_nm := public.bank_legacy_migrate_notes(p_batch);
  -- 自動で解消: 銀行側のみだった明細が旧行と対応した／期間内で対応が無かった旧行が銀行の明細と対応した
  update public.bank_diff_items d set status = 'resolved', decided_at = now(), decided_reason = '自動: 後の取り出しで、旧行と銀行の明細が 1 対 1 に対応した', resolved_at = now(), resolved_batch = p_batch
   where d.status in ('open', 'held') and d.kind = 'bank_only' and cardinality(d.transaction_ids) > 0
     and not exists (select 1 from unnest(d.transaction_ids) t(id) where not exists (select 1 from public.bank_legacy_links k where k.kind = 'paired' and k.transaction_id = t.id));
  update public.bank_diff_items d set status = 'resolved', decided_at = now(), decided_reason = '自動: 後の取り出しで、旧行と銀行の明細が 1 対 1 に対応した', resolved_at = now(), resolved_batch = p_batch
   where d.status in ('open', 'held') and d.kind = 'legacy_only_in_window'
     and exists (select 1 from public.bank_legacy_links k where k.legacy_key = d.legacy_keys[1] and k.kind = 'paired');
  -- 「前回から増えた旧行」の記録は、対応づけ・移行が済んだら（リンクができたら）自動で解消済みにする（参考情報。削除された行・修正の候補は、人が見るまで残す）
  update public.bank_diff_items d set status = 'resolved', decided_at = now(), decided_reason = '自動: 増えた旧行は、対応づけ・移行が済んだ', resolved_at = now(), resolved_batch = p_batch
   where d.status in ('open', 'held') and d.kind = 'added_since_prev' and exists (select 1 from public.bank_legacy_links k where k.legacy_key = d.legacy_keys[1]);
  -- 店舗×日付の不一致（旧シートの取り出し ⇔ 正本の日次集計）
  drop table if exists _rc_m;
  create temporary table _rc_m on commit drop as
    with L as (select store_id, txn_date, count(*) c, sum(amount) a from public.bank_legacy_rows where batch_id = p_batch and store_id is not null group by 1, 2),
         D as (select store_id, deposit_date txn_date, deposit_count c, amount a from public.bank_deposit_daily()),
         C as (select coalesce(L.store_id, D.store_id) store_id, coalesce(L.txn_date, D.txn_date) txn_date, coalesce(L.c, 0) lc, coalesce(L.a, 0) la, coalesce(D.c, 0) dc, coalesce(D.a, 0) da
                 from L full join D on L.store_id = D.store_id and L.txn_date = D.txn_date)
    select c.*, k.kinds, coalesce(array_to_string(k.kinds, '+'), 'unexplained') cause,
           coalesce(k.all_timing, false) is_timing
      from C c left join lateral (
             select array_agg(distinct d.kind order by d.kind) kinds,
                    bool_and(coalesce((d.detail ->> 'timing')::boolean, false)) filter (where d.kind not in ('added_since_prev', 'removed_since_prev')) all_timing   -- 追加・削除の記録は参考情報（タイミング差の判定には使わない）
               from public.bank_diff_items d
              where d.status in ('open', 'held') and d.store_id = c.store_id and d.txn_date = c.txn_date
                and d.kind in ('bank_only', 'legacy_only_in_window', 'paired_held', 'ambiguous_pair', 'modified_candidate', 'added_since_prev', 'removed_since_prev')) k on true
     where c.lc <> c.dc or c.la <> c.da;
  select count(*), count(*) filter (where cause = 'unexplained'), count(*) filter (where is_timing),
         count(*) filter (where not exists (select 1 from public.bank_reconcile_mismatches o where o.store_id = _rc_m.store_id and o.txn_date = _rc_m.txn_date and o.status = 'open'))
    into v_open, v_unexp, v_timing, v_new from _rc_m;
  select count(*) into v_resolved from public.bank_reconcile_mismatches o where o.status = 'open' and not exists (select 1 from _rc_m m where m.store_id = o.store_id and m.txn_date = o.txn_date);
  v_status := case when (select count(*) from _rc_m where not is_timing) = 0 then 'ok' else 'mismatch' end;
  select count(*) into v_lrows from public.bank_legacy_rows where batch_id = p_batch;
  select count(*) into v_csv from public.bank_transactions where source_kind in ('playwright', 'manual_csv');
  select count(*) into v_paired from public.bank_legacy_links where kind = 'paired';
  select count(*) into v_ul from public.bank_diff_items where kind = 'legacy_only_in_window' and status in ('open', 'held');
  select count(*) into v_ub from public.bank_diff_items where kind = 'bank_only' and status in ('open', 'held');
  select count(distinct (c.store_id, c.txn_date)) into v_sd from (select store_id, txn_date from public.bank_legacy_rows where batch_id = p_batch and store_id is not null union select store_id, deposit_date from public.bank_deposit_daily()) c;
  select coalesce(sum(amount), 0) into v_lt from public.bank_legacy_rows where batch_id = p_batch and store_id is not null;
  select coalesce(sum(amount), 0) into v_dt from public.bank_deposit_daily();
  insert into public.bank_reconcile_runs (run_date, batch_id, prev_batch_id, legacy_rows, ledger_csv_rows, paired_total, unpaired_legacy, unpaired_bank, changes, store_dates,
                                          mismatches_open, mismatches_unexplained, mismatches_timing, mismatches_new, mismatches_resolved, legacy_total, ledger_total, status)
  values (v_date, p_batch, p_prev, v_lrows, v_csv, v_paired, v_ul, v_ub, v_chg, v_sd, v_open, v_unexp, v_timing, v_new, v_resolved, v_lt, v_dt, v_status) returning id into v_run;
  -- 不一致の記録: 続いているもの＝更新（日数を数える）／新しいもの＝追加／無くなったもの＝自動で解消済み
  update public.bank_reconcile_mismatches o set last_run_id = v_run, legacy_count = m.lc, ledger_count = m.dc, legacy_amount = m.la, ledger_amount = m.da, cause = m.cause, is_timing = m.is_timing,
         days_open = v_date - (o.created_at at time zone 'Asia/Tokyo')::date
    from _rc_m m where o.status = 'open' and o.store_id = m.store_id and o.txn_date = m.txn_date;
  insert into public.bank_reconcile_mismatches (store_id, txn_date, first_run_id, last_run_id, legacy_count, ledger_count, legacy_amount, ledger_amount, cause, is_timing)
    select m.store_id, m.txn_date, v_run, v_run, m.lc, m.dc, m.la, m.da, m.cause, m.is_timing from _rc_m m
     where not exists (select 1 from public.bank_reconcile_mismatches o where o.status = 'open' and o.store_id = m.store_id and o.txn_date = m.txn_date);
  update public.bank_reconcile_mismatches o set status = 'auto_resolved', resolved_run_id = v_run, resolved_at = now()
   where o.status = 'open' and not exists (select 1 from _rc_m m where m.store_id = o.store_id and m.txn_date = o.txn_date);
  return jsonb_build_object('run_id', v_run, 'status', v_status, 'run_date', v_date, 'changes', v_chg, 'plan', v_pl, 'migrate', v_mg, 'notes', v_nm,
    'mismatches_open', v_open, 'unexplained', v_unexp, 'timing', v_timing, 'new', v_new, 'resolved', v_resolved,
    'legacy_total', v_lt, 'ledger_total', v_dt, 'unpaired_legacy', v_ul, 'unpaired_bank', v_ub, 'paired_total', v_paired);
end $$;

-- 14 日間の経過（読むだけ。本部・社長・マスター、またはサービスロール）: 実行ごとの結果・連続して ok の日数・いま続いている不一致（原因・日数つき）
create or replace function public.bank_reconcile_report(p_days integer default 14)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
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
end $$;

revoke all on function public.bank_reconcile_run(uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.bank_reconcile_run(uuid, uuid, date) to service_role;
revoke all on function public.bank_reconcile_report(integer) from public, anon;
grant execute on function public.bank_reconcile_report(integer) to authenticated, service_role;
revoke all on function public.bank_legacy_plan(uuid) from public, anon, authenticated;
grant execute on function public.bank_legacy_plan(uuid) to service_role;
