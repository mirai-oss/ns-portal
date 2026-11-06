-- =============================================================
-- 画像日報 v4（2026-11-06）: 口コミ件数を「看板（Google掲載）ごと」に持ち、2枚看板・3枚看板の店舗は内訳を表示
-- 指示: ユーザー「ダブル看板やトリプル看板がある店舗に関しては、口コミ件数は各看板ごとの詳細も出したい」(2026-11-06)
-- 背景: 口コミ推移ログ（正本）は 1行＝1 Google掲載（例: 黒霧屋 新横浜／カラオケ 彩-irodori 新横浜アリーナ通り店／うお蔵 新横浜）。
--   v3 の keiei-kd-refresh op=reviews は店舗ID×取得日で 1 行に潰していたため、最後に読んだ看板の件数だけが残っていた
--   （黒霧屋 新横浜＝うお蔵の 649 件のみ）。ダッシュボード reviewIncrease は親＋子看板の合計なので画像と食い違っていた。
-- 本ファイル:
--   1) kd_google_review_listings（看板ごとのスナップショット。EF op=reviews が書く）
--   2) store_aliases.display_name（看板の短い表示名。画像の内訳行に使う）
--   3) daily_report_card_vm v4: 店舗合計＝看板ごとの最新累計の合計（ダッシュボードと同じ）、google_review_listings[] を追加
-- 適用: python3 scripts/apply_sql.py supabase/2026-11-06_daily_report_card_v4_review_listings.sql
--   （この後 keiei-kd-refresh を再デプロイ。EF が旧版の間は従来の店舗合計スナップショットで動く＝内訳なし）
-- =============================================================
create table if not exists public.kd_google_review_listings (
  store_id       uuid not null,
  listing_name   text not null,               -- 口コミ推移ログの「店舗名」列そのまま（＝Google掲載の識別名）
  fetched_on     date not null,
  total_count    int,
  avg_star       numeric,
  delta          int,
  google_name    text,                        -- 「Google名称」列（あれば）
  synced_at      timestamptz not null default now(),
  primary key (store_id, listing_name, fetched_on)
);
alter table public.kd_google_review_listings enable row level security;
drop policy if exists kd_google_review_listings_read on public.kd_google_review_listings;
create policy kd_google_review_listings_read on public.kd_google_review_listings for select to authenticated using (true);
grant select on public.kd_google_review_listings to authenticated;

alter table public.store_aliases add column if not exists display_name text;
comment on column public.store_aliases.display_name is '看板（kind=listing）の短い表示名。画像日報の口コミ内訳に使う（例: 彩／うお蔵／匠味）';
update public.store_aliases set display_name = v.d from (values
  ('カラオケ 彩-irodori 新横浜アリーナ通り店', '彩'),
  ('彩 新横浜', '彩'),
  ('うお蔵 新横浜', 'うお蔵'),
  ('匠味 新横浜', '匠味'),
  ('匠味 川崎', '匠味'),
  ('個室×焼き鳥 博多焼き鳥食べ放題 鶏武者 新横浜店', '鶏武者')
) as v(a, d) where store_aliases.alias = v.a and store_aliases.display_name is null;

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
-- Google 口コミ（看板＝Google掲載ごと）: 当日以前の最新スナップショットと、月初より前の最新スナップショット（月間増加の起点）
-- kd_google_review_listings に行が無い店舗（EF 旧版のまま等）は従来の店舗合計スナップショットを「1看板」として扱う
grsrc as (
  select l.listing_name, l.fetched_on, l.total_count, l.avg_star from kd_google_review_listings l, p where l.store_id = p.sid
  union all
  select st.name, s.fetched_on, s.total_count, s.avg_star from kd_google_review_snapshots s, p, st
   where s.store_id = p.sid and not exists (select 1 from kd_google_review_listings l2 where l2.store_id = p.sid)
),
grl as (
  select x.listing_name, (array_agg(x.total_count order by x.fetched_on desc))[1] as end_total,
         (array_agg(x.avg_star order by x.fetched_on desc))[1] as end_star, max(x.fetched_on) as end_on
  from grsrc x, p where x.fetched_on <= p.dt group by x.listing_name
),
grs as (
  select x.listing_name, (array_agg(x.total_count order by x.fetched_on desc))[1] as start_total
  from grsrc x, ms where x.fetched_on < ms.m0 group by x.listing_name
),
grx as (
  select e.listing_name, e.end_total, e.end_star, e.end_on, s.start_total,
         case when s.start_total is not null then greatest(0, e.end_total - s.start_total) end as inc,
         -- 表示名: store_aliases.display_name（看板の短い名前）→ 無ければ店舗名の先頭語（「黒霧屋 新横浜」→「黒霧屋」）
         coalesce(a.display_name, split_part(e.listing_name, ' ', 1)) as label,
         case when e.listing_name = st.name then 0 else 1 end as ord
  from grl e
  left join grs s on s.listing_name = e.listing_name
  left join lateral (select al.display_name from store_aliases al, p where al.alias = e.listing_name and al.store_id = p.sid limit 1) a on true
  , st
),
gr_end as (
  select sum(end_total)::int as total_count,
         case when sum(end_total) > 0 then round((sum(coalesce(end_star,0) * end_total) / sum(end_total))::numeric, 2) end as avg_star,
         max(end_on) as fetched_on, count(*) as n
  from grx having count(*) > 0
),
gr_start as (select sum(start_total)::int as total_count, count(*) as n from grx where start_total is not null having count(*) > 0)
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
  -- 看板（Google掲載）ごとの内訳: 2看板以上の店舗で画像に表示（label=短い表示名・month_increase は起点が無ければ null → 画像は「—件」）
  'google_review_listings', coalesce((select jsonb_agg(jsonb_build_object('name', listing_name, 'label', label, 'total', end_total, 'month_increase', inc, 'updated_at', end_on) order by ord, label) from grx), '[]'::jsonb),
  'google_review_listing_count', (select count(*) from grx),
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
