-- =============================================================
-- 日報カード（Slack 画像日報）の ViewModel（2026-11-05・Slack通知基盤 Phase 1-b 拡張）
-- 指示書: ユーザー「Slack日報通知を画像1枚＋最小限テキストに」。設計メモは tori-dashboard HANDOFF.md 2026-11-05。
-- 正本: 経営ダッシュボードの日次集計（kd_daily_store_full / kd_detail_hour_daily）・予算（dash_sales_target_daily / kd_target_monthly_v）
--       画像側で独自計算はしない。管理システムと同じ表を読むだけ。
-- 前年: prior_year_same_weekday_sales（364日前＝前年の同じ曜日）。※現行の文章日報(GAS reportDataBQ)は「前年の同じ日付」なので値が違う。
-- ランチ/ディナー: kd_detail_hour_daily（明細ベース）。両方そろい、合計が当日売上と±1%以内のときだけ画像に出す（判定は描画側）。
-- 口コミ件数・ダイニー点数: ハブに表が無いため null（スプレッドシート側のみ）。将来 kd_* に鏡が出来たら埋める。
-- 権限: service_role のみ（Edge Function daily-report-card 経由で使う）。anon/authenticated からは呼べない。
-- 適用: python3 scripts/apply_sql.py supabase/2026-11-05_daily_report_card.sql   戻し方: drop function + bucket は残してよい
-- =============================================================
create or replace function public.daily_report_card_vm(p_store uuid, p_date date)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
with p as (select p_store as sid, p_date as dt),
st as (select s.id, s.name, s.store_no, s.file_key from stores s, p where s.id = p.sid),
d as (select k.* from kd_daily_store_full k, p where k.store_id = p.sid and k.date = p.dt),
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
spm as (select coalesce(sum(e.amount),0) amt from kd_spot_entries e, p, ms where e.store_id = p.sid and e.work_date between ms.m0 and p.dt)
select jsonb_build_object(
  'store_id', st.id, 'store_name', st.name, 'store_no', st.store_no, 'file_key', st.file_key,
  'date', p.dt, 'weekday_ja', (array['日','月','火','水','木','金','土'])[extract(dow from p.dt)::int + 1],
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
  'ly_same_weekday_sales', (select prior_year_same_weekday_sales from d),
  'yoy_same_weekday_ratio', (select case when prior_year_same_weekday_sales > 0 then net_sales / prior_year_same_weekday_sales end from d),
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
  'target_dinii', (select dinii_target from tm), 'target_review', (select review_target from tm),
  'mtd_review_count', null, 'mtd_dinii_score', null,
  'generated_at', now()
) as vm
from p, st
$function$;
revoke all on function public.daily_report_card_vm(uuid, date) from public, anon, authenticated;
grant execute on function public.daily_report_card_vm(uuid, date) to service_role;

-- 店舗名で引く版（Edge Function が store_name しか持たない経路用）
create or replace function public.daily_report_card_vm_by_name(p_store_name text, p_date date)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select public.daily_report_card_vm(s.id, p_date) from public.stores s where s.name = p_store_name and s.is_active limit 1
$function$;
revoke all on function public.daily_report_card_vm_by_name(text, date) from public, anon, authenticated;
grant execute on function public.daily_report_card_vm_by_name(text, date) to service_role;

-- 画像の保存先（公開バケット。Slack の画像ブロックが URL を読むため公開が必要。中身は日報の数字だけ）
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('daily-report', 'daily-report', true, 5242880, array['image/png'])
on conflict (id) do update set public = true;
