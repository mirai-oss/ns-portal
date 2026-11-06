-- =============================================================
-- 画像日報 v3（2026-11-06）: 今月累計に「口コミ件数（Google）」「ダイニー点数（点数＋件数）」を正本データから表示
-- 指示書: ユーザー「日報画像 KPI表示修正指示書」(2026-11-06)
-- 正本: 経営ダッシュボードのスプレッドシート
--   ・ダイニーDB（Dinii 来店アンケート。ns-daily-import dinii-questionnaire が毎日取込。1行=1回答・「また来たい点数」）
--   ・口コミ推移ログ（Google 口コミのスナップショット: 取得日・店舗名・累計件数・平均星・前回比。週1回）
--   を keiei-kd-refresh op=reviews が kd_dinii_responses / kd_google_review_snapshots に鏡写しする。
-- 定義（ダッシュボードと同じ・画像側で独自計算しない）:
--   ダイニー点数 = 月初〜当日に来店した回答の「また来たい点数」の平均（diniiStats）・件数 = その回答数
--   口コミ件数   = 月間増加（当日以前の最新スナップショット累計 − 月初より前の最新スナップショット累計。reviewIncrease）
-- 適用: python3 scripts/apply_sql.py supabase/2026-11-06_daily_report_card_v3_reviews.sql
-- =============================================================
create table if not exists public.kd_dinii_responses (
  response_key   text primary key,           -- 店舗名+来店日時+LINE ID のハッシュ（取込側の重複キーと同じ構成）
  store_id       uuid not null,
  store_name_raw text not null,
  visited_at     timestamptz,
  answered_at    timestamptz,
  score          numeric,                     -- また来たい点数（元の値のまま）
  synced_at      timestamptz not null default now()
);
create index if not exists kd_dinii_responses_store_visit_idx on public.kd_dinii_responses (store_id, visited_at);
create table if not exists public.kd_google_review_snapshots (
  store_id       uuid not null,
  fetched_on     date not null,               -- 取得日（シートの取得日そのまま）
  store_name_raw text not null,
  total_count    int,                         -- 累計件数
  avg_star       numeric,                     -- 平均星
  delta          int,                         -- 前回比
  synced_at      timestamptz not null default now(),
  primary key (store_id, fetched_on)
);
alter table public.kd_dinii_responses enable row level security;
alter table public.kd_google_review_snapshots enable row level security;
drop policy if exists kd_dinii_responses_read on public.kd_dinii_responses;
create policy kd_dinii_responses_read on public.kd_dinii_responses for select to authenticated using (true);
drop policy if exists kd_google_review_snapshots_read on public.kd_google_review_snapshots;
create policy kd_google_review_snapshots_read on public.kd_google_review_snapshots for select to authenticated using (true);
grant select on public.kd_dinii_responses, public.kd_google_review_snapshots to authenticated;

-- ViewModel v3（v2 ＋ 口コミ・ダイニー）
create or replace function public.daily_report_card_vm(p_store uuid, p_date date)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
with p as (select p_store as sid, p_date as dt, public.jp_prev_year_same_nth_weekday(p_date) as cdt),
st as (select s.id, s.name, s.store_no, s.file_key, s.event_area from stores s, p where s.id = p.sid),
d as (select k.* from kd_daily_store_full k, p where k.store_id = p.sid and k.date = p.dt),
ly as (select k.net_sales, k.guests_total from kd_daily_store_full k, p where p.cdt is not null and k.store_id = p.sid and k.date = p.cdt),
ms as (select date_trunc('month', p.dt)::date as m0 from p),
mtd as (
  select sum(k.net_sales) sales, sum(k.cogs) cogs, sum(k.labor_cost_total) labor, sum(k.guests_total) guests, count(*) days
  from kd_daily_store_full k, p, ms where k.store_id = p.sid and k.date between ms.m0 and p.dt
),
bt as (select t.sales_target from dash_sales_target_daily t, p where t.store_id = p.sid and t.biz_date = p.dt),
bm as (select sum(t.sales_target) sales_target from dash_sales_target_daily t, p, ms where t.store_id = p.sid and t.biz_date between ms.m0 and p.dt),
tm as (select t.* from kd_target_monthly_v t, p where t.store_id = p.sid and t.year_month = to_char(p.dt, 'YYYY-MM')),
ld as (
  select h.daypart, sum(h.sales_excl) sales, sum(h.checks) checks, sum(h.guests_otoshi) guests
  from kd_detail_hour_daily h, p where h.store_id = p.sid and h.biz_date = p.dt group by h.daypart
),
sp as (select coalesce(sum(e.amount),0) amt from kd_spot_entries e, p where e.store_id = p.sid and e.work_date = p.dt),
spm as (select coalesce(sum(e.amount),0) amt from kd_spot_entries e, p, ms where e.store_id = p.sid and e.work_date between ms.m0 and p.dt),
ev as (
  -- その日のイベント: 店舗のエリアの会場 or 対象店舗に指定されているもの。優先順: 近い会場(sort_order)→集客規模→開始時刻
  select e.event_id, coalesce(v.name, e.venue_name) venue, e.event_name, to_char(e.start_time, 'HH24:MI') start_time,
         to_char(e.end_time, 'HH24:MI') end_time, e.expected_attendance,
         row_number() over (order by coalesce(v.sort_order, 999), e.expected_attendance desc nulls last, e.start_time nulls last, e.event_name) rn
  from kd_events e left join event_venues v on v.venue_key = e.venue_key, p, st
  where e.event_date = p.dt and e.confirmed
    and ((st.event_area is not null and e.area = st.event_area) or st.id = any(e.target_store_ids))
),
hol as (select public.jp_holiday_name(p.dt) as name from p),
-- ダイニー来店アンケート（また来たい点数）: 月初〜当日の来店分の平均と件数（経営ダッシュボード diniiStats と同じ定義・独自換算なし）
dn as (
  select round(avg(r.score)::numeric, 2) as score, count(*) as cnt, max(r.visited_at) as last_at
  from kd_dinii_responses r, p, ms
  where r.store_id = p.sid and r.score is not null
    and (r.visited_at at time zone 'Asia/Tokyo')::date between ms.m0 and p.dt
),
-- Google 口コミ: 当日以前の最新スナップショット（累計件数・平均星・取得日）と、月初より前の最新スナップショット（月間増加の起点）
gr_end as (select s.total_count, s.avg_star, s.fetched_on from kd_google_review_snapshots s, p where s.store_id = p.sid and s.fetched_on <= p.dt order by s.fetched_on desc limit 1),
gr_start as (select s.total_count from kd_google_review_snapshots s, p, ms where s.store_id = p.sid and s.fetched_on < ms.m0 order by s.fetched_on desc limit 1)
select jsonb_build_object(
  'store_id', st.id, 'store_name', st.name, 'store_no', st.store_no, 'file_key', st.file_key, 'event_area', st.event_area,
  'date', p.dt, 'weekday_ja', (array['日','月','火','水','木','金','土'])[extract(dow from p.dt)::int + 1],
  'is_weekend', extract(dow from p.dt)::int in (0, 6),
  'is_holiday', (select name from hol) is not null, 'holiday_name', (select name from hol),
  'has_data', (select count(*) from d) > 0,
  'sales_today', (select net_sales from d),
  'guests_today', (select guests_total from d),
  'parties_today', (select parties_total from d),
  'avg_spend_today', (select case when guests_total > 0 then round(net_sales / guests_total) end from d),
  'cogs_today', (select cogs from d),
  'labor_today', (select labor_cost_total from d) + (select amt from sp),
  'food_cost_ratio_today', (select case when net_sales > 0 then cogs / net_sales end from d),
  'labor_ratio_today', (select case when net_sales > 0 then (labor_cost_total + (select amt from sp)) / net_sales end from d),
  'budget_today', (select sales_target from bt),
  'budget_ratio_today', (select case when (select sales_target from bt) > 0 then net_sales / (select sales_target from bt) end from d),
  -- 前年比: 前年同月の第N週・同曜日（比較対象が無い月は ly_found=false・比率 null → 画像は「—」）
  'ly_comparison_date', p.cdt,
  'ly_week_index', ceil(extract(day from p.dt) / 7.0)::int,
  'ly_found', p.cdt is not null,
  'ly_has_data', (select count(*) from ly) > 0,
  'ly_sales', (select net_sales from ly),
  'ly_guests', (select guests_total from ly),
  'yoy_same_week_ratio', (select case when (select net_sales from ly) > 0 then net_sales / (select net_sales from ly) end from d),
  'lunch', (select jsonb_build_object('sales', sales, 'checks', checks, 'guests', guests, 'avg_spend', case when guests > 0 then round(sales / guests) end) from ld where daypart = 'lunch'),
  'dinner', (select jsonb_build_object('sales', sales, 'checks', checks, 'guests', guests, 'avg_spend', case when guests > 0 then round(sales / guests) end) from ld where daypart = 'dinner'),
  'mtd_from', (select m0 from ms), 'mtd_days', (select days from mtd),
  'mtd_sales', (select sales from mtd), 'mtd_guests', (select guests from mtd),
  'mtd_budget', (select sales_target from bm), 'mtd_budget_ratio', (select case when (select sales_target from bm) > 0 then sales / (select sales_target from bm) end from mtd),
  'month_budget', (select sales_target from tm),
  'mtd_food_cost_ratio', (select case when sales > 0 then cogs / sales end from mtd),
  'mtd_labor_ratio', (select case when sales > 0 then (labor + (select amt from spm)) / sales end from mtd),
  'target_labor_rate', (select (coalesce(pa_rate,0) + coalesce(emp_rate,0)) / 100.0 from tm),
  'target_food_cost_rate', (select cost_rate / 100.0 from tm),
  'target_dinii', (select dinii_target from tm), 'target_review', (select review_target from tm)
) || jsonb_build_object(
  -- 口コミ件数（Google）: 月間増加（期間末スナップショット − 月初前スナップショット。ダッシュボード reviewIncrease と同じ）＋累計・取得日
  'google_review_total', (select total_count from gr_end),
  'google_review_avg_star', (select avg_star from gr_end),
  'google_review_updated_at', (select fetched_on from gr_end),
  'google_review_month_increase', (select case when (select count(*) from gr_end) > 0 and (select count(*) from gr_start) > 0
                                     then greatest(0, (select total_count from gr_end) - (select total_count from gr_start)) end),
  'mtd_review_count', (select case when (select count(*) from gr_end) > 0 and (select count(*) from gr_start) > 0
                                     then greatest(0, (select total_count from gr_end) - (select total_count from gr_start)) end),
  -- ダイニー点数: 月初〜当日の「また来たい点数」の平均（小数2桁）と回答件数。回答が無ければ null（0 にしない）
  'mtd_dinii_score', (select case when cnt > 0 then score end from dn),
  'mtd_dinii_count', (select case when cnt > 0 then cnt end from dn),
  'dinii_updated_at', (select last_at from dn),
  'events', coalesce((select jsonb_agg(jsonb_build_object('event_id', event_id, 'venue', venue, 'event_name', event_name, 'start_time', start_time, 'end_time', end_time, 'expected_attendance', expected_attendance) order by rn) from ev), '[]'::jsonb),
  'events_total', (select count(*) from ev),
  'generated_at', now()
) as vm
from p, st
$function$;
revoke all on function public.daily_report_card_vm(uuid, date) from public, anon, authenticated;
grant execute on function public.daily_report_card_vm(uuid, date) to service_role;
