-- 2026-11-11 担当A（TK-244 第1弾）: F/L/FL 共通定義（正本）。★草案・本番未適用★ 司令塔レビュー後、ユーザー承認→ユーザー実行。
-- 目的: 日報VM・kd_store_monthly_summary・経営ダッシュボードが同じ F/L/FL を参照できるようにする（設計書 §4.2）。
-- 定義（設計書 §4.1・確定）:
--   売上KPI（本日の売上・累計・予算比・前年比）は店内売上のまま。ここで変えるのは F率・L率・FL比率の「分母」だけ。
--   FL計算用売上(fl_sales) = 店内売上(kd_dashboard_daily_summary.net_sales) + デリバリー売上（kd_delivery_daily.net_sales を税抜へ換算）
--   デリバリーの税抜換算 = ÷ fl_delivery_tax_divisor()（既定 1.08 = 税込8%。Q11 の最終回答で変わる場合はこの1か所だけ直す）
--   L率 = 人件費 ÷ fl_sales ／ F率 = 食材原価 ÷ fl_sales ／ FL比率 = L率 + F率
--   人件費 = kd_daily_store_full.labor_cost_total（PA＋社員）＋ kd_spot_entries（スポット）＝日報VM v5 と同じ範囲
--   食材原価 = kd_daily_store_full.cogs（日報VM v5 と同じ）
-- 影響: 新規関数のみ（既存の関数・表・列は変更しない）＋ kd_store_monthly_summary に列追加2つ（NULL許容・既存の値は変えない）。
-- 【rollback】drop function fl_metrics_month(uuid,text), fl_metrics_mtd(uuid,date), fl_metrics_day(uuid,date), fl_metrics_range(uuid,date,date), fl_metrics_calc(numeric,numeric,numeric,numeric), fl_delivery_tax_divisor();
--   alter table kd_store_monthly_summary drop column fl_sales, drop column fl_delivery_sales;

-- 1) 換算率（定数1か所）
create or replace function public.fl_delivery_tax_divisor() returns numeric
language sql immutable as $$ select 1.08::numeric $$;

-- 2) 純粋計算（テスト用・他の関数もここを通す）。p_delivery_ex = 税抜換算「後」のデリバリー売上
create or replace function public.fl_metrics_calc(p_instore numeric, p_delivery_ex numeric, p_labor numeric, p_cost numeric)
returns jsonb language sql immutable as $$
  with x as (select coalesce(p_instore,0) + coalesce(p_delivery_ex,0) as fl)
  select jsonb_build_object(
    'instore_sales', coalesce(p_instore,0),
    'delivery_sales', coalesce(p_delivery_ex,0),
    'fl_sales', x.fl,
    'labor', p_labor, 'cost', p_cost,
    'l_rate', case when x.fl > 0 and p_labor is not null then p_labor / x.fl end,
    'f_rate', case when x.fl > 0 and p_cost is not null then p_cost / x.fl end,
    'fl_ratio', case when x.fl > 0 and p_labor is not null and p_cost is not null then (p_labor + p_cost) / x.fl end)
  from x
$$;

-- 3) 期間集計（店舗×期間）。日次／月初〜当日／月の3粒度はこの薄いラッパー
create or replace function public.fl_metrics_range(p_store uuid, p_from date, p_to date)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with k as (
    select sum(net_sales) sales, sum(labor_cost_total) labor, sum(cogs) cogs, count(*) days
    from kd_daily_store_full where store_id = p_store and date between p_from and p_to),
  sp as (select coalesce(sum(amount),0) amt from kd_spot_entries where store_id = p_store and work_date between p_from and p_to),
  dv as (select coalesce(sum(net_sales),0) gross, coalesce(sum(orders),0) orders, count(*) n from kd_delivery_daily where store_id = p_store and biz_date between p_from and p_to)
  select public.fl_metrics_calc(k.sales, dv.gross / public.fl_delivery_tax_divisor(),
                                case when k.days > 0 then coalesce(k.labor,0) + sp.amt end, case when k.days > 0 then k.cogs end)
         || jsonb_build_object('delivery_sales_gross', dv.gross, 'delivery_orders', dv.orders, 'delivery_rows', dv.n, 'days', k.days,
                               'from', p_from, 'to', p_to, 'tax_divisor', public.fl_delivery_tax_divisor())
  from k, sp, dv
$$;
create or replace function public.fl_metrics_day(p_store uuid, p_date date) returns jsonb
language sql stable security definer set search_path to 'public' as $$ select public.fl_metrics_range(p_store, p_date, p_date) $$;
create or replace function public.fl_metrics_mtd(p_store uuid, p_date date) returns jsonb
language sql stable security definer set search_path to 'public' as $$ select public.fl_metrics_range(p_store, date_trunc('month', p_date)::date, p_date) $$;
create or replace function public.fl_metrics_month(p_store uuid, p_ym text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select public.fl_metrics_range(p_store, (p_ym || '-01')::date, ((p_ym || '-01')::date + interval '1 month - 1 day')::date) $$;
revoke all on function public.fl_metrics_range(uuid,date,date), public.fl_metrics_day(uuid,date), public.fl_metrics_mtd(uuid,date), public.fl_metrics_month(uuid,text) from public, anon, authenticated;
grant execute on function public.fl_metrics_range(uuid,date,date), public.fl_metrics_day(uuid,date), public.fl_metrics_mtd(uuid,date), public.fl_metrics_month(uuid,text) to service_role;
grant execute on function public.fl_delivery_tax_divisor(), public.fl_metrics_calc(numeric,numeric,numeric,numeric) to service_role;

-- 4) 月次サマリに FL計算用売上を持つ列を追加（売上列 sales は店内のまま・意味を変えない）。値は keiei-kd-refresh（別途小さい差分）が埋める
alter table public.kd_store_monthly_summary add column if not exists fl_sales numeric;
alter table public.kd_store_monthly_summary add column if not exists fl_delivery_sales numeric;
comment on column public.kd_store_monthly_summary.fl_sales is 'FL計算用売上=店内売上+デリバリー(税抜換算後)。labor_rate/cost_rate/fl_rate の分母（TK-244）。sales は店内のまま';

-- 端数: 換算は丸めない（numericのまま集計）。日次の合計＝月間と必ず一致する。表示側が円に丸める。取消行はマイナスのまま合算（net_sales が既に相殺・値引き後）
-- 5) 計算検証（適用後に実行する確認用SELECT。期待: fl_sales=8000000 / l_rate=0.2 / f_rate=0.25 / fl_ratio=0.45）
--   select public.fl_metrics_calc(7000000, 1000000, 1600000, 2000000);
--   換算の確認: 税込1,080,000 → select round(1080000 / public.fl_delivery_tax_divisor());  -- 期待 1000000
