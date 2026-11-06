-- =============================================================
-- 画像日報 v2（2026-11-06）: 前年比を「前年同月の第N週・同曜日」に統一／祝日名／新横浜エリアのイベント表示
-- 指示書: ユーザー「日報画像機能の追加修正指示」(2026-11-06)。
-- 1) jp_prev_year_same_nth_weekday(date): 比較対象日（共通ロジック）。正本は tori-dashboard shared/prev-year-date.js。
--    GAS gas/Code.gs getPreviousYearComparableDate と同じ。**3箇所は必ず揃えて直すこと**。
--    前年同月に同じ第N曜日が無いときは null（第4曜日などへ代替しない）。
-- 2) jp_national_holiday_name / jp_holiday_name: 祝日名。判定の正本は既存 jp_is_national_holiday / jp_is_holiday（計算式）。
--    名前は app.js jpNationalHolidayName / jpHolidayName と同じ表。
-- 3) event_venues（会場マスタ: 会場→エリア・優先順）・kd_events（DB_イベント の鏡。keiei-kd-refresh op=events が同期）・
--    stores.event_area（店舗のイベントエリア。店舗名の文字列一致では判定しない）。
-- 4) daily_report_card_vm を v2 に（新キー: ly_comparison_date/ly_week_index/ly_found/ly_sales/yoy_same_week_ratio、
--    is_holiday/holiday_name/is_weekend、events/events_total）。旧キー ly_same_weekday_sales/yoy_same_weekday_ratio は廃止。
-- 適用: python3 scripts/apply_sql.py supabase/2026-11-06_daily_report_card_v2.sql
-- =============================================================

-- 1) 前年同月の第N週・同曜日
create or replace function public.jp_prev_year_same_nth_weekday(p_date date)
returns date
language sql
immutable
as $function$
  with x as (
    select extract(dow from p_date)::int as dow,
           ceil(extract(day from p_date) / 7.0)::int as n,
           make_date(extract(year from p_date)::int - 1, extract(month from p_date)::int, 1) as first
  ),
  y as (
    select first, first + ((dow - extract(dow from first)::int + 7) % 7) + 7 * (n - 1) as cand from x
  )
  select case when extract(month from cand) = extract(month from first) then cand end from y
$function$;

-- 2) 祝日名（判定は既存の jp_is_national_holiday / 振替休日・国民の休日のロジックに従う）
create or replace function public.jp_national_holiday_name(p_date date)
returns text
language plpgsql
immutable
as $function$
declare
  v_m int := extract(month from p_date)::int;
  v_d int := extract(day from p_date)::int;
  v_dow int := extract(dow from p_date)::int;
  v_w int := ceil(v_d / 7.0)::int;
begin
  if not public.jp_is_national_holiday(p_date) then return null; end if;
  if (v_m, v_d) = (1, 1) then return '元日'; end if;
  if (v_m, v_d) = (2, 11) then return '建国記念の日'; end if;
  if (v_m, v_d) = (2, 23) then return '天皇誕生日'; end if;
  if (v_m, v_d) = (4, 29) then return '昭和の日'; end if;
  if (v_m, v_d) = (5, 3) then return '憲法記念日'; end if;
  if (v_m, v_d) = (5, 4) then return 'みどりの日'; end if;
  if (v_m, v_d) = (5, 5) then return 'こどもの日'; end if;
  if (v_m, v_d) = (8, 11) then return '山の日'; end if;
  if (v_m, v_d) = (11, 3) then return '文化の日'; end if;
  if (v_m, v_d) = (11, 23) then return '勤労感謝の日'; end if;
  if v_dow = 1 then
    if v_m = 1 and v_w = 2 then return '成人の日'; end if;
    if v_m = 7 and v_w = 3 then return '海の日'; end if;
    if v_m = 9 and v_w = 3 then return '敬老の日'; end if;
    if v_m = 10 and v_w = 2 then return 'スポーツの日'; end if;
  end if;
  if v_m = 3 then return '春分の日'; end if;
  if v_m = 9 then return '秋分の日'; end if;
  return '祝日';
end;
$function$;

create or replace function public.jp_holiday_name(p_date date)
returns text
language plpgsql
immutable
as $function$
declare v_p date; v_n text;
begin
  v_n := public.jp_national_holiday_name(p_date);
  if v_n is not null then return v_n; end if;
  -- 振替休日: 直前に連続する祝日の中に日曜があれば、その後の最初の「祝日でない日」
  v_p := p_date - 1;
  while public.jp_is_national_holiday(v_p) loop
    if extract(dow from v_p)::int = 0 then return '振替休日'; end if;
    v_p := v_p - 1;
  end loop;
  -- 国民の休日: 前日と翌日がともに祝日
  if public.jp_is_national_holiday(p_date - 1) and public.jp_is_national_holiday(p_date + 1) then return '国民の休日'; end if;
  return null;
end;
$function$;

-- 3) 会場マスタ・イベント鏡・店舗のイベントエリア
create table if not exists public.event_venues (
  venue_key   text primary key,
  name        text not null unique,            -- DB_イベント の「会場」と同じ表記
  area        text not null,                   -- 例: shin_yokohama
  lat         numeric, lon numeric,
  sort_order  int not null default 100,        -- 小さいほど優先（店舗に近い会場を小さく）
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
insert into public.event_venues (venue_key, name, area, lat, lon, sort_order) values
  ('yokohama_arena', '横浜アリーナ',   'shin_yokohama', 35.5096, 139.6195, 10),
  ('nissan_stadium', '日産スタジアム', 'shin_yokohama', 35.5101, 139.6064, 20)
on conflict (venue_key) do nothing;

alter table public.stores add column if not exists event_area text;
comment on column public.stores.event_area is 'イベント表示のエリア（例 shin_yokohama）。event_venues.area と一致する会場のイベントを日報に出す。店舗名では判定しない';
update public.stores set event_area = 'shin_yokohama' where store_no in ('06', '08', '10') and event_area is null;

create table if not exists public.kd_events (
  event_id            text primary key,          -- DB_イベント の ID（自動取得 ya_…／手動 8桁）
  venue_key           text references public.event_venues(venue_key),
  venue_name          text,
  event_name          text not null,
  event_date          date not null,
  start_time          time,
  end_time            time,
  expected_attendance int,
  area                text,
  source              text,                      -- auto / manual
  confirmed           boolean not null default true,
  target_store_ids    uuid[] not null default '{}',   -- DB_イベント「対象店舗」を店舗IDに解決したもの
  target_store_names  text[] not null default '{}',
  memo                text,
  synced_at           timestamptz not null default now()
);
create index if not exists kd_events_date_idx on public.kd_events (event_date);
alter table public.event_venues enable row level security;
alter table public.kd_events enable row level security;
drop policy if exists event_venues_read on public.event_venues;
create policy event_venues_read on public.event_venues for select to authenticated using (true);
drop policy if exists kd_events_read on public.kd_events;
create policy kd_events_read on public.kd_events for select to authenticated using (true);
grant select on public.event_venues, public.kd_events to authenticated;

-- 4) ViewModel v2
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
hol as (select public.jp_holiday_name(p.dt) as name from p)
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
  'target_dinii', (select dinii_target from tm), 'target_review', (select review_target from tm),
  'mtd_review_count', null, 'mtd_dinii_score', null,
  'events', coalesce((select jsonb_agg(jsonb_build_object('event_id', event_id, 'venue', venue, 'event_name', event_name, 'start_time', start_time, 'end_time', end_time, 'expected_attendance', expected_attendance) order by rn) from ev), '[]'::jsonb),
  'events_total', (select count(*) from ev),
  'generated_at', now()
) as vm
from p, st
$function$;
revoke all on function public.daily_report_card_vm(uuid, date) from public, anon, authenticated;
grant execute on function public.daily_report_card_vm(uuid, date) to service_role;

-- 検算用（適用時に表示）: 2026-11-03(火・第1) → 2025-11-04 ／ 2026-11-30(月・第5) → null ／ 祝日名
select d, public.jp_prev_year_same_nth_weekday(d) as cmp, public.jp_holiday_name(d) as holiday
from unnest(array['2026-11-03','2026-11-04','2026-11-20','2026-11-30','2026-11-23','2026-05-06','2026-11-07']::date[]) as d;
