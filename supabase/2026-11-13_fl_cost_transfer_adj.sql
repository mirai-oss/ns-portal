-- 2026-11-13 担当A（TK-252）: 店舗間移動（サムゲタン等の仕入れ移動）を F/L/FL の原価に反映する。
-- 背景: 日報・月次サマリの原価は kd_daily_store_full.cogs（日次の仕入）だけで、pl_entries の「店舗間移動」行（移動元=マイナス／受入側=プラス）が入っておらず、
--       経営ダッシュボード（cur.cost + PLのF区分）と原価率が合わなかった。ユーザー指示（2026-11-11）で、移動した側・受け入れた側とも反映する。
-- 定義: 原価(F) = cogs ＋ 店舗間移動(pl_entries: source='店舗間移動'・category='F'・未削除)の金額。日付は memo 末尾の移動日（店舗間移動:<id>:YYYY-MM-DD）。
--       店舗間移動は全店合計で0になる（付け替えのみ）。仕入高差額調整など月次のF行は日報には入れない（月末の確定調整のため）。
-- 影響: 新関数 fl_transfer_adj() 追加＋ fl_metrics_range の cost に加算（cost_transfer_adj キーも追加）。呼び出し元（日報VM・fl_metrics_day/mtd/month）は無変更で追従。
-- 【指紋ガード】fl_metrics_range が未変更（kd_daily_store_full を含み fl_transfer_adj を含まない）でなければ中止。
-- 【rollback】fl_metrics_range を 2026-11-11_fl_metrics_common.sql の定義で create or replace し直し、drop function fl_transfer_adj(uuid,date,date)。

do $guard$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'fl_metrics_range' and pronamespace = 'public'::regnamespace;
  if v_src is null or v_src not like '%kd_daily_store_full%' or v_src like '%fl_transfer_adj%' then
    raise exception 'fl_metrics_range が想定の状態ではありません（未作成 or 適用済み）。中止します';
  end if;
end
$guard$;

create or replace function public.fl_transfer_adj(p_store uuid, p_from date, p_to date) returns numeric
language sql stable security definer set search_path to 'public' as $$
  select coalesce(sum(amount), 0) from public.pl_entries
   where deleted_at is null and source = '店舗間移動' and category = 'F' and store_id = p_store
     and memo ~ ':\d{4}-\d{2}-\d{2}$'
     and (substring(memo from ':(\d{4}-\d{2}-\d{2})$'))::date between p_from and p_to
$$;
revoke all on function public.fl_transfer_adj(uuid,date,date) from public, anon, authenticated;
grant execute on function public.fl_transfer_adj(uuid,date,date) to service_role;

create or replace function public.fl_metrics_range(p_store uuid, p_from date, p_to date)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with k as (
    select sum(net_sales) sales, sum(labor_cost_total) labor, sum(cogs) cogs, count(*) days
    from kd_daily_store_full where store_id = p_store and date between p_from and p_to),
  sp as (select coalesce(sum(amount),0) amt from kd_spot_entries where store_id = p_store and work_date between p_from and p_to),
  tr as (select public.fl_transfer_adj(p_store, p_from, p_to) amt),
  dv as (select coalesce(sum(net_sales),0) gross, coalesce(sum(orders),0) orders, count(*) n from kd_delivery_daily where store_id = p_store and biz_date between p_from and p_to)
  select public.fl_metrics_calc(k.sales, dv.gross / public.fl_delivery_tax_divisor(),
                                case when k.days > 0 then coalesce(k.labor,0) + sp.amt end, case when k.days > 0 then coalesce(k.cogs,0) + tr.amt end)
         || jsonb_build_object('delivery_sales_gross', dv.gross, 'delivery_orders', dv.orders, 'delivery_rows', dv.n, 'days', k.days,
                               'from', p_from, 'to', p_to, 'tax_divisor', public.fl_delivery_tax_divisor(), 'cost_transfer_adj', tr.amt)
  from k, sp, tr, dv
$$;
revoke all on function public.fl_metrics_range(uuid,date,date) from public, anon, authenticated;
grant execute on function public.fl_metrics_range(uuid,date,date) to service_role;
