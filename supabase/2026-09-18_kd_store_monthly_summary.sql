-- レーンP: TK-63 kd_store_monthly_summary（設計書_表示集計層kdと高速化実行計画_2026-09-02.md §3・
-- 実装指示書_ラウンド6_2026-09-18.md §1 A-12支援）
--
-- 目的: 経営ダッシュボードのトップKPIカード（原価率F・人件費率L・FL合計）は、app.js viewDash()が
-- D.daily（sales/cost/pa/emp/labor）＋D.spot（スポット人件費）から計算している（app.js:1448
-- stat()参照）。kd_dashboard_daily_summaryには売上・原価・人件費合計はあるが、pa（パート）/emp
-- （社員）の内訳が無くこのKPIを安全に置き換えられなかった（2026-09-11判定・TK-60の既知ブロッカー）。
-- 本テーブルは店舗×年月でこの内訳＋予算比較を持つ。
--
-- ---------------------------------------------------------------------
-- 0. kd_dashboard_daily_summaryへpa/emp列を追加（bqDailyStoreFull()が既に取得しているのに
--    保存していなかった列。cost/laborと同じ経緯）
-- ---------------------------------------------------------------------
alter table public.kd_dashboard_daily_summary add column if not exists labor_pa numeric;   -- parttime_labor_cost（パート・アルバイト人件費）
alter table public.kd_dashboard_daily_summary add column if not exists labor_emp numeric;  -- fulltime_labor_cost（社員人件費）
comment on column public.kd_dashboard_daily_summary.labor_pa is 'PA(パート・アルバイト)人件費・自動。fact_daily_store.parttime_labor_cost。labor列(pa+emp合計)の内訳';
comment on column public.kd_dashboard_daily_summary.labor_emp is '社員人件費・自動。fact_daily_store.fulltime_labor_cost。labor列(pa+emp合計)の内訳';

-- ---------------------------------------------------------------------
-- 1. kd_store_monthly_summary
-- ---------------------------------------------------------------------
create table if not exists public.kd_store_monthly_summary (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id),
  corporation_id uuid references public.corporations (id),
  year_month text not null check (year_month ~ '^\d{4}-\d{2}$'),
  sales numeric,                 -- kd_dashboard_daily_summary.net_salesの月合計
  cost numeric,                  -- 原価(F)自動・同cost列の月合計
  cost_rate numeric,             -- cost/sales
  labor_pa numeric,              -- PA人件費・月合計
  labor_emp numeric,             -- 社員人件費・月合計
  labor_spot numeric,            -- スポット人件費（stg_spot・bqGetSpot経由）・月合計
  labor_total numeric,           -- labor_pa+labor_emp+labor_spot（app.js stat()のlabor+spotと同じ定義）
  labor_rate numeric,            -- labor_total/sales
  fl_rate numeric,               -- cost_rate+labor_rate
  gross_profit numeric,          -- sales-cost（粗利。人件費控除前。plAgg()のgross定義と同じ）
  budget_sales numeric,          -- dash_sales_target_dailyの月合計（売上目標）
  budget_diff numeric,           -- sales-budget_sales
  budget_rate numeric,           -- sales/budget_sales
  source_updated_at timestamptz,
  computed_at timestamptz not null default now(),
  source_count int not null default 0,
  sync_run_id uuid references public.kd_sync_runs (id)
);
create unique index if not exists kd_store_monthly_summary_unique on public.kd_store_monthly_summary (store_id, year_month);
create index if not exists kd_store_monthly_summary_ym_idx on public.kd_store_monthly_summary (year_month desc);
create index if not exists kd_store_monthly_summary_corp_ym_idx on public.kd_store_monthly_summary (corporation_id, year_month);

alter table public.kd_store_monthly_summary enable row level security;
drop policy if exists kd_store_monthly_summary_select on public.kd_store_monthly_summary;
create policy kd_store_monthly_summary_select on public.kd_store_monthly_summary
  for select to authenticated using (
    exists (
      select 1 from public.users u
      where u.id = auth.uid() and u.is_active and (
        u.is_master or u.role in ('CEO', 'HQ', 'TEAM')
        or (u.role = 'TENCHO' and exists (
              select 1 from public.user_stores us where us.user_id = u.id and us.store_id = kd_store_monthly_summary.store_id
            ))
      )
    )
  );

comment on table public.kd_store_monthly_summary is
  'TK-63: 経営ダッシュボードのトップKPI(F率/L率/FL計)・予算比較を店舗×年月で持つ。営業利益等フルP&Lはkd_pl_monthly_summaryが正本（重複させない）。';
