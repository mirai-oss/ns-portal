-- レーンP: 経営D F2用kd_追加（依頼_レーンP_経営D_F2用kd追加_2026-10-05.md #1〜#4）
--
-- 【事前報告様式（DB変更）】
-- 理由: 担当AのF1完了後、経営Dで「GASの確定データ待ち（初回30秒〜1分）」が残るのは目標管理・広告管理・媒体・明細・入金の詳細。
--       これらが必要とする列（現金売上・人件費内訳・広告費・目標）がkd_に無いため。
-- 現構造: kd_dashboard_daily_summary(店舗×日)にnet_sales/guests/parties/cost/labor/labor_pa/labor_emp。入金は月次(kd_deposit_monthly_summary)のみ。
--         広告・目標はkd_なし(目標のみdash_target_monthly/dash_sales_target_dailyがSupabaseにある)。
-- 変更（既存の列・行・RLS・APIの返り値は不変。追加のみ）:
--   #1 kd_dashboard_daily_summaryへ cash / employee_salary_bonus / statutory_welfare / commute_allowance を追加（BQ fact_daily_store と同名）。
--      依頼名 kd_daily_store_full は「別テーブルで二重管理」せず、同じ表を fact_daily_store 互換の列名で見せるビュー
--      （1つの数字に正本は1つ）。画面が使う列（app.js stat()）はこれで全て揃う。
--   #2 kd_deposit_daily（店舗×日の入金。明細はentriesにjsonb）＋ビュー kd_deposit_daily_v（現金売上・入金・差額）
--      ＋ビュー kd_deposit_carry_v（店舗×月初の繰越＝月初より前の「現金売上−入金」累計。GAS depositCarry と同じ定義）
--   #3 kd_ad_monthly（店舗×媒体×月: 広告費・プラン内訳・広告効果(アクセス/予約/電話/集客手数料)・PL除外フラグ）
--   #4 ビュー kd_target_monthly_v（店舗×月: 売上目標(日別目標の月合計)・F率/PA率/社員率目標・ダイニー/口コミ目標）
-- 既存データへの影響: 列追加(null許容)・新規テーブル/ビューのみ。
-- migration: 本ファイル(何度流しても壊れない)。 rollback: 追加列drop／新規テーブル・ビューdrop（他から参照されない新規物のため即戻せる）

-- ---------------------------------------------------------------------
-- #1 日次の写し（列追加＋fact_daily_store互換ビュー）
-- ---------------------------------------------------------------------
alter table public.kd_dashboard_daily_summary add column if not exists cash numeric;                  -- 現金売上
alter table public.kd_dashboard_daily_summary add column if not exists employee_salary_bonus numeric;  -- 社員給与・賞与
alter table public.kd_dashboard_daily_summary add column if not exists statutory_welfare numeric;      -- 法定福利費
alter table public.kd_dashboard_daily_summary add column if not exists commute_allowance numeric;      -- 通勤手当
comment on column public.kd_dashboard_daily_summary.cash is 'fact_daily_store.cash（現金売上）。入金管理の「累計未入金」の元';
comment on column public.kd_dashboard_daily_summary.employee_salary_bonus is 'fact_daily_store.employee_salary_bonus（app.js empBase）';
comment on column public.kd_dashboard_daily_summary.statutory_welfare is 'fact_daily_store.statutory_welfare（app.js welfare）';
comment on column public.kd_dashboard_daily_summary.commute_allowance is 'fact_daily_store.commute_allowance（app.js commute）';

create or replace view public.kd_daily_store_full with (security_invoker = true) as
select
  store_id,
  corporation_id,
  period_date                       as date,
  net_sales,
  guests                            as guests_total,
  parties                           as parties_total,
  labor_pa                          as parttime_labor_cost,
  labor_emp                         as fulltime_labor_cost,
  labor                             as labor_cost_total,
  cost                              as cogs,
  cash,
  employee_salary_bonus,
  statutory_welfare,
  commute_allowance,
  avg_check,
  prior_year_same_weekday_sales,
  prior_year_same_weekday_ratio,
  computed_at,
  sync_run_id
from public.kd_dashboard_daily_summary;
comment on view public.kd_daily_store_full is
  'BQ fact_daily_store互換の列名で見せるkd_dashboard_daily_summaryのビュー(実体は1つ)。GAS bqDailyStoreが返す13列＋客単価・前年同曜日比。in/out客数・クレジット/ポイント内訳などbqDailyStoreが返さない列は含まない';

-- ---------------------------------------------------------------------
-- #2 入金（日次・繰越）
-- ---------------------------------------------------------------------
create table if not exists public.kd_deposit_daily (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id),
  corporation_id uuid references public.corporations (id),
  deposit_date date not null,
  amount numeric not null default 0,            -- その日の入金額合計
  deposit_count int not null default 0,
  entries jsonb not null default '[]'::jsonb,   -- [{"a":金額,"m":"メモ"}]（入金一覧の明細表示用）
  source_updated_at timestamptz,
  computed_at timestamptz not null default now(),
  source_count int not null default 0,
  sync_run_id uuid references public.kd_sync_runs (id)
);
create unique index if not exists kd_deposit_daily_unique on public.kd_deposit_daily (store_id, deposit_date);
create index if not exists kd_deposit_daily_date_idx on public.kd_deposit_daily (deposit_date desc);
alter table public.kd_deposit_daily enable row level security;
drop policy if exists kd_deposit_daily_select on public.kd_deposit_daily;
create policy kd_deposit_daily_select on public.kd_deposit_daily
  for select to authenticated using (
    exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (
      u.is_master or u.role in ('CEO', 'HQ', 'TEAM')
      or (u.role = 'TENCHO' and exists (select 1 from public.user_stores us where us.user_id = u.id and us.store_id = kd_deposit_daily.store_id))
    ))
  );

-- 店舗×日の「現金売上・入金額・差額」（どちらか片方しか無い日も出す）
create or replace view public.kd_deposit_daily_v with (security_invoker = true) as
select
  coalesce(c.store_id, d.store_id)       as store_id,
  coalesce(c.period_date, d.deposit_date) as date,
  coalesce(c.cash, 0)                    as cash_sales,
  coalesce(d.amount, 0)                  as deposit_amount,
  coalesce(c.cash, 0) - coalesce(d.amount, 0) as diff,
  coalesce(d.deposit_count, 0)           as deposit_count,
  coalesce(d.entries, '[]'::jsonb)       as entries
from (select store_id, period_date, cash from public.kd_dashboard_daily_summary) c
full outer join public.kd_deposit_daily d on d.store_id = c.store_id and d.deposit_date = c.period_date;

-- 店舗×月の繰越（月初より前の現金売上−入金の累計。GAS depositCarry と同じ定義: 全期間・店舗ごと）
create or replace view public.kd_deposit_carry_v with (security_invoker = true) as
with stores_ever as (
  select store_id from public.kd_dashboard_daily_summary
  union select store_id from public.kd_deposit_daily
),
months as (
  select m::date as month_start
  from generate_series(
    date_trunc('month', least(
      coalesce((select min(period_date) from public.kd_dashboard_daily_summary), current_date),
      coalesce((select min(deposit_date) from public.kd_deposit_daily), current_date))),
    date_trunc('month', (now() at time zone 'Asia/Tokyo')::date + interval '2 months'),
    interval '1 month') as m
)
select
  s.store_id,
  to_char(m.month_start, 'YYYY-MM') as year_month,
  m.month_start,
  coalesce((select sum(c.cash) from public.kd_dashboard_daily_summary c where c.store_id = s.store_id and c.period_date < m.month_start), 0) as cash_before,
  coalesce((select sum(d.amount) from public.kd_deposit_daily d where d.store_id = s.store_id and d.deposit_date < m.month_start), 0) as deposit_before,
  coalesce((select sum(c.cash) from public.kd_dashboard_daily_summary c where c.store_id = s.store_id and c.period_date < m.month_start), 0)
  - coalesce((select sum(d.amount) from public.kd_deposit_daily d where d.store_id = s.store_id and d.deposit_date < m.month_start), 0) as carry
from stores_ever s cross join months m;
comment on view public.kd_deposit_carry_v is '入金の繰越。carry=cash_before−deposit_before（月初より前の累計）。年月を指定して読むこと（全期間×全店舗の組合せを持つ）';

-- ---------------------------------------------------------------------
-- #3 広告（店舗×媒体×月）
-- ---------------------------------------------------------------------
create table if not exists public.kd_ad_monthly (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id),
  corporation_id uuid references public.corporations (id),
  year_month text not null check (year_month ~ '^\d{4}-\d{2}$'),
  media_name text not null,                          -- tpl_media_aliasで正規化（未登録表記はそのまま）
  ad_cost numeric,                                   -- 広告費（stg_ad_cost＝広告費DBのBQミラー）
  plan_breakdown jsonb not null default '{}'::jsonb, -- {"プラン名":金額}
  access_count numeric,                              -- 広告効果シート: アクセス数
  net_groups numeric, net_people numeric, tel_count numeric,  -- ネット予約組数・人数／電話数
  total_groups numeric, total_people numeric, total_sales numeric, -- 総組数・総人数・総売上
  acquisition_fee numeric,                           -- 集客手数料
  pl_excluded boolean not null default false,        -- 広告除外設定(店舗×月)＝PLの「媒体販促費(自動)」をゼロ扱いにする月（店舗×月単位。同店舗同月の全媒体行に同じ値）
  source_updated_at timestamptz,
  computed_at timestamptz not null default now(),
  source_count int not null default 0,
  sync_run_id uuid references public.kd_sync_runs (id)
);
create unique index if not exists kd_ad_monthly_unique on public.kd_ad_monthly (store_id, year_month, media_name);
create index if not exists kd_ad_monthly_ym_idx on public.kd_ad_monthly (year_month desc);
alter table public.kd_ad_monthly enable row level security;
drop policy if exists kd_ad_monthly_select on public.kd_ad_monthly;
create policy kd_ad_monthly_select on public.kd_ad_monthly
  for select to authenticated using (
    exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (
      u.is_master or u.role in ('CEO', 'HQ', 'TEAM')
      or (u.role = 'TENCHO' and exists (select 1 from public.user_stores us where us.user_id = u.id and us.store_id = kd_ad_monthly.store_id))
    ))
  );

-- ---------------------------------------------------------------------
-- #4 目標（店舗×月）。実体は既存のdash_target_monthly(月次目標)とdash_sales_target_daily(日別売上目標)。
--   画面側が使いやすいよう1行にまとめるビュー。dash_*のRLS状況に依存しないよう、APIはservice_role＋自前スコープ判定で読む
--   （ビュー自体はauthenticated/anonに公開しない）。
-- ---------------------------------------------------------------------
create or replace view public.kd_target_monthly_v as
select
  t.store_id,
  to_char(t.ym, 'YYYY-MM')                    as year_month,
  (select sum(d.sales_target) from public.dash_sales_target_daily d
     where d.store_id = t.store_id and d.biz_date >= t.ym and d.biz_date < (t.ym + interval '1 month')) as sales_target,
  (select count(*) from public.dash_sales_target_daily d
     where d.store_id = t.store_id and d.biz_date >= t.ym and d.biz_date < (t.ym + interval '1 month') and d.sales_target is not null) as target_days,
  t.pa_rate, t.emp_rate, t.cost_rate,
  t.dinii_target, t.review_target,
  t.updated_at,
  t.ym                                         as ym   -- 従来のkind:'target'(dash_target_monthly直読み)との互換用(月初日)
from public.dash_target_monthly t;
revoke all on public.kd_target_monthly_v from anon, authenticated;
comment on view public.kd_target_monthly_v is '店舗×月の目標（売上目標=日別目標の月合計、PA率・社員率・F率(原価率)目標、ダイニー点数・口コミ件数目標）。keiei-api-dashboard-summary経由で読む';
