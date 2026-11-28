-- 段階3（2026-11-28_bank_ledger_stage3.sql）の取り消し。状態: 下書き（未適用）
-- 新しい 7 つの表のどれかに 1 行でもデータがあれば、何も消さずに止まる（移行したデータ・決定の記録を守る）。
-- 日次集計の関数 bank_deposit_daily は、段階1の定義に戻す（手動調整を数えない元の形）。移行済みの手動調整の行が残っていれば、数字が変わるので止まる。
do $$
declare n bigint := 0; t text; c bigint; v_adj bigint := 0;
begin
  foreach t in array array['bank_legacy_batches', 'bank_legacy_rows', 'bank_legacy_notes', 'bank_legacy_links', 'bank_diff_items', 'bank_decision_batches', 'bank_diff_decisions'] loop
    if to_regclass('public.' || t) is not null then execute format('select count(*) from public.%I', t) into c; n := n + c; end if;
  end loop;
  select count(*) into v_adj from public.bank_transactions where tx_kind = 'adjustment' and counts_as_sales_deposit;
  if n > 0 then raise exception '段階3の表にすでに % 件のデータが入っています。取り消しを中止しました（データを守るため）', n; end if;
  if v_adj > 0 then raise exception '手動調整の行が % 件あるため、日次集計を元の定義に戻せません。取り消しを中止しました', v_adj; end if;
end $$;

drop function if exists public.bank_diff_decide(uuid[], text, text, text);
drop function if exists public.bank_legacy_report(uuid);
drop function if exists public.bank_csv_rows_fingerprint();
drop function if exists public.bank_legacy_migrate_notes(uuid);
drop function if exists public.bank_legacy_migrate(uuid);
drop function if exists public.bank_legacy_changes(uuid, uuid);
drop function if exists public.bank_legacy_plan(uuid);
drop function if exists public.bank_legacy_load(jsonb, jsonb, jsonb);
drop table if exists public.bank_diff_decisions;
drop table if exists public.bank_decision_batches;
drop table if exists public.bank_diff_items;
drop table if exists public.bank_legacy_links;
drop table if exists public.bank_legacy_notes;
drop table if exists public.bank_legacy_rows;
drop table if exists public.bank_legacy_batches;
drop function if exists public.bank_legacy_guard();

-- 段階1の定義に戻す
create or replace function public.bank_deposit_daily(p_from date default null, p_to date default null)
returns table (store_id uuid, corporation_id uuid, deposit_date date, amount numeric, deposit_count integer,
               entries jsonb, legacy_pending_count integer, held_count integer, held_amount numeric, new_count integer,
               last_changed_at timestamptz)
language sql stable security definer set search_path to 'public' as $$
  with e as (
    select t.*,
           coalesce(t.adj_txn_date, t.txn_date)             as eff_date,
           coalesce(t.adj_deposit_amount, t.deposit_amount) as eff_dep,
           coalesce(t.adj_description, t.description)       as eff_desc
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
   where e.eff_dep > 0
     and (p_from is null or e.eff_date >= p_from) and (p_to is null or e.eff_date <= p_to)
   group by e.store_id, e.corporation_id, e.eff_date
$$;
revoke all on function public.bank_deposit_daily(date, date) from public, anon;
grant execute on function public.bank_deposit_daily(date, date) to authenticated, service_role;
