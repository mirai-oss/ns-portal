-- =============================================================
-- Google口コミ Supabase直結化 ①（2026-11-06）
--   Google Places API (New) → Supabase を正本にし、スプレッドシート（口コミPlaceID／口コミ推移ログ）を経路から外す。
--   設計書: docs/設計書_Google口コミSupabase直結_2026-11-06.md
--   1) google_place_listings  … Google掲載マスタ（店舗 1 : N 掲載。自社発行 listing_id → Google place_id を固定キーに）
--   2) google_review_snapshots … 毎日の口コミ履歴（listing_id × fetched_on で冪等）。新 Edge Function google-reviews-fetch だけが書く
--   3) google_review_fetch_runs … 取得の実行記録（API 呼出回数・成功/失敗。コスト監視）
--   4) 初期 seed: 既存 kd_google_review_listings の（店舗ID×掲載名）12 件 → マスタ（place_id 未確定 = status 'pending'）
--      履歴の一回限りの引き継ぎ: kd_google_review_listings（旧シート鏡）→ google_review_snapshots（source='legacy_sheet'）
--      ※以後、旧シート取込（keiei-kd-refresh op=reviews）は kd_google_review_listings（比較専用）にだけ書き、新正本には触れない
--   5) 集計: google_review_store_kpi(店舗, 日付)（今日/今週(火〜月)/今月の増加・看板別内訳。マイナスも保持）、
--      google_review_store_daily_v・google_review_kpi_v・google_review_legacy_compare_v（旧新比較）
--   6) daily_report_card_vm v5: 口コミを新正本から読む（greatest(0,…) の丸めを廃止）
--   適用: python3 scripts/apply_sql.py supabase/2026-11-06_google_reviews_direct.sql  （先に --dry-run）
--   Cron は別ファイル 2026-11-06_google_reviews_cron.sql（pg_cron 有効化後）
-- =============================================================

-- 1) Google掲載マスタ -------------------------------------------------------
create table if not exists public.google_place_listings (
  id                  uuid primary key default gen_random_uuid(),
  store_id            uuid not null references public.stores(id),
  listing_name        text not null,                 -- 自社での掲載名（旧 口コミ推移ログ「店舗名」列と同じ表記。表示用・キーにはしない）
  display_name        text,                          -- 画像日報の短い看板名（彩／うお蔵／匠味…）
  place_id            text unique,                   -- Google Place ID（確定後に入る。確定前は null）
  google_display_name text,                          -- Google 上の名称（取得のたびに最新化）
  google_address      text,                          -- Google 上の住所（確定時）
  source_reference    text,                          -- 由来（旧シートの行・URL など）
  search_query        text,                          -- 初期解決用の Text Search 語（null なら listing_name）
  address_hint        text,                          -- 住所照合の手がかり（例: 横浜市／川崎市）。null なら住所照合を省略
  status              text not null default 'pending'
                      check (status in ('pending','active','needs_review','inactive','invalid')),
  is_primary          boolean not null default false, -- 店舗の主看板（店舗名と同じ掲載）
  sort_order          integer not null default 0,
  candidates          jsonb,                         -- 解決時の候補一覧（人間確認用: id/name/address/details）
  review_note         text,                          -- needs_review の理由・管理者メモ
  last_verified_at    timestamptz,                   -- Place ID を人が/自動で確認した日時
  last_fetched_at     timestamptz,                   -- 最後に Place Details を取れた日時
  last_error          text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  unique (store_id, listing_name)
);
comment on table public.google_place_listings is 'Google掲載マスタ（店舗1:N）。status=active かつ place_id ありが毎日取得の対象。掲載名は表示用で、識別は id（listing_id）→place_id';
create index if not exists google_place_listings_store_idx on public.google_place_listings (store_id, sort_order);
alter table public.google_place_listings enable row level security;
drop policy if exists google_place_listings_read on public.google_place_listings;
create policy google_place_listings_read on public.google_place_listings for select to authenticated using (true);
grant select on public.google_place_listings to authenticated;

create or replace function public.google_place_listings_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists google_place_listings_touch on public.google_place_listings;
create trigger google_place_listings_touch before update on public.google_place_listings
  for each row execute function public.google_place_listings_touch();

-- 2) 口コミ履歴（新正本） ---------------------------------------------------
create table if not exists public.google_review_snapshots (
  id                  bigint generated always as identity primary key,
  listing_id          uuid not null references public.google_place_listings(id),
  store_id            uuid not null references public.stores(id),
  fetched_on          date not null,                                   -- 取得日（JST）
  as_of_date          date generated always as (fetched_on - 1) stored, -- 「前日までの実績」として扱う基準日（経営ダッシュボードと同じ）
  fetched_at          timestamptz not null default now(),
  total_count         integer,                                         -- 累計口コミ数（userRatingCount）
  rating              numeric(3,2),                                    -- 平均星（rating）
  google_display_name text,
  source              text not null default 'places_api',              -- places_api | legacy_sheet（初期引き継ぎのみ）
  created_at          timestamptz not null default now(),
  unique (listing_id, fetched_on)
);
comment on table public.google_review_snapshots is 'Google口コミの日次スナップショット（生の累計値）。増加数は保存せず View/関数で計算。マイナス差分も事実として保持';
create index if not exists google_review_snapshots_store_asof_idx on public.google_review_snapshots (store_id, as_of_date desc);
create index if not exists google_review_snapshots_listing_asof_idx on public.google_review_snapshots (listing_id, as_of_date desc);
alter table public.google_review_snapshots enable row level security;
drop policy if exists google_review_snapshots_read on public.google_review_snapshots;
create policy google_review_snapshots_read on public.google_review_snapshots for select to authenticated using (true);
grant select on public.google_review_snapshots to authenticated;

-- 3) 実行記録（コスト監視） -------------------------------------------------
create table if not exists public.google_review_fetch_runs (
  id                   bigint generated always as identity primary key,
  op                   text not null,                 -- fetch | resolve
  run_on               date not null,                 -- JST
  started_at           timestamptz not null default now(),
  finished_at          timestamptz,
  status               text not null default 'running', -- running | success | partial | failed
  listings_total       integer not null default 0,
  ok_count             integer not null default 0,
  fail_count           integer not null default 0,
  api_calls            integer not null default 0,
  text_search_calls    integer not null default 0,
  place_details_calls  integer not null default 0,
  error                text,
  detail               jsonb
);
alter table public.google_review_fetch_runs enable row level security;
drop policy if exists google_review_fetch_runs_read on public.google_review_fetch_runs;
create policy google_review_fetch_runs_read on public.google_review_fetch_runs for select to authenticated using (true);
grant select on public.google_review_fetch_runs to authenticated;

-- 4) 初期 seed（鳥一代グループ 8 店の 12 掲載。N-Style 4 店は対象外＝行を作らない） ----------
insert into public.google_place_listings (store_id, listing_name, display_name, is_primary, sort_order, source_reference)
select x.store_id, x.listing_name,
       coalesce(a.display_name, split_part(x.listing_name, ' ', 1)),
       x.listing_name = s.name,
       case when x.listing_name = s.name then 0 else 1 end,
       'seed 2026-11-06: 売上DB「口コミPlaceID」行（口コミ推移ログの掲載名）'
from (select distinct store_id, listing_name from public.kd_google_review_listings) x
join public.stores s on s.id = x.store_id
left join public.store_aliases a on a.alias = x.listing_name and a.store_id = x.store_id and a.kind = 'listing'
on conflict (store_id, listing_name) do nothing;

-- 住所照合の手がかり（分かるものだけ。null は住所照合を省略し、旧履歴の件数照合だけで判定）
update public.google_place_listings set address_hint = v.h
from (values ('新横浜', '横浜市'), ('川崎', '川崎市'), ('恵比寿', '渋谷区'), ('新橋', '港区'), ('芝の鳥一代', '港区')) as v(k, h)
where google_place_listings.address_hint is null and google_place_listings.listing_name like '%' || v.k || '%';

-- 履歴の一回限りの引き継ぎ（旧シート鏡 → 新正本。source='legacy_sheet'。以後は新 EF しか書かない）
insert into public.google_review_snapshots (listing_id, store_id, fetched_on, fetched_at, total_count, rating, google_display_name, source)
select m.id, l.store_id, l.fetched_on, coalesce(l.synced_at, now()), l.total_count, l.avg_star, l.google_name, 'legacy_sheet'
from public.kd_google_review_listings l
join public.google_place_listings m on m.store_id = l.store_id and m.listing_name = l.listing_name
on conflict (listing_id, fetched_on) do nothing;

-- 5) 集計 ---------------------------------------------------------------------
-- 店舗×基準日の KPI。週は経営ダッシュボードの週報と同じ「火曜〜翌月曜」。基準日 = as_of_date（取得日の前日）。
--   total/rating: 各看板の「基準日以前の最新」を合算（星は件数加重平均）
--   day_inc:   基準日の値 − 前日の値（両方そろう看板だけ合算。1つも無ければ null）
--   week_inc:  基準日以前の最新 − 週開始日より前の最新（起点のある看板だけ合算）
--   month_inc: 基準日以前の最新 − 月初より前の最新（同上）。マイナスはそのまま返す
--   旧テーブルにしか無い店舗（将来の移行途中など）は kd_google_review_listings を 1 看板ずつとして同じ式で扱う
create or replace function public.google_review_store_kpi(p_store uuid, p_date date)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
with p as (select p_store as sid, p_date as dt,
                  date_trunc('month', p_date)::date as m0,
                  (p_date - ((extract(dow from p_date)::int - 2 + 7) % 7))::date as w0),
src as (
  select s.listing_id, m.listing_name, coalesce(m.display_name, split_part(m.listing_name, ' ', 1)) as label,
         m.is_primary, m.sort_order, s.as_of_date, s.fetched_on, s.total_count, s.rating
  from google_review_snapshots s join google_place_listings m on m.id = s.listing_id, p
  where s.store_id = p.sid and m.status not in ('inactive', 'invalid')
  union all
  select null::uuid, l.listing_name, coalesce(a.display_name, split_part(l.listing_name, ' ', 1)),
         l.listing_name = st.name, case when l.listing_name = st.name then 0 else 1 end,
         l.fetched_on - 1, l.fetched_on, l.total_count, l.avg_star
  from kd_google_review_listings l join stores st on st.id = l.store_id
  left join store_aliases a on a.alias = l.listing_name and a.store_id = l.store_id and a.kind = 'listing', p
  where l.store_id = p.sid and not exists (select 1 from google_review_snapshots g where g.store_id = p.sid)
),
latest as (select distinct on (listing_name) * from src, p where as_of_date <= p.dt order by listing_name, as_of_date desc),
dprev  as (select distinct on (listing_name) listing_name, total_count from src, p where as_of_date = p.dt - 1 order by listing_name, as_of_date desc),
wprev  as (select distinct on (listing_name) listing_name, total_count from src, p where as_of_date < p.w0 order by listing_name, as_of_date desc),
mprev  as (select distinct on (listing_name) listing_name, total_count from src, p where as_of_date < p.m0 order by listing_name, as_of_date desc),
x as (
  select l.listing_id, l.listing_name, l.label, l.is_primary, l.sort_order, l.as_of_date, l.fetched_on, l.total_count, l.rating,
         case when l.as_of_date = p.dt and d.total_count is not null then l.total_count - d.total_count end as day_inc,
         case when w.total_count is not null then l.total_count - w.total_count end as week_inc,
         case when m.total_count is not null then l.total_count - m.total_count end as month_inc
  from latest l cross join p
  left join dprev d on d.listing_name = l.listing_name
  left join wprev w on w.listing_name = l.listing_name
  left join mprev m on m.listing_name = l.listing_name
)
select jsonb_build_object(
  'store_id', p.sid, 'date', p.dt, 'week_start', p.w0, 'month_start', p.m0,
  'listing_count', (select count(*) from x),
  'total', (select sum(total_count)::int from x),
  'rating', (select case when sum(total_count) > 0 then round((sum(coalesce(rating, 0) * total_count) / sum(total_count))::numeric, 2) end from x),
  'as_of_date', (select max(as_of_date) from x),
  'fetched_on', (select max(fetched_on) from x),
  'day_inc',   (select sum(day_inc)::int   from x where day_inc is not null),
  'week_inc',  (select sum(week_inc)::int  from x where week_inc is not null),
  'month_inc', (select sum(month_inc)::int from x where month_inc is not null),
  'listings', coalesce((select jsonb_agg(jsonb_build_object(
      'listing_id', listing_id, 'name', listing_name, 'label', label, 'is_primary', is_primary,
      'total', total_count, 'rating', rating, 'as_of_date', as_of_date, 'fetched_on', fetched_on,
      'day_inc', day_inc, 'week_inc', week_inc, 'month_inc', month_inc)
      order by (case when is_primary then 0 else 1 end), sort_order, label) from x), '[]'::jsonb)
) from p
$function$;
revoke all on function public.google_review_store_kpi(uuid, date) from public, anon;
grant execute on function public.google_review_store_kpi(uuid, date) to authenticated, service_role;

-- 店舗×基準日の合計（取得があった日だけ。看板ごとの「その日以前の最新」を合算）
create or replace view public.google_review_store_daily_v as
with d as (select distinct store_id, as_of_date from public.google_review_snapshots)
select d.store_id, d.as_of_date,
       sum(l.total_count)::int as total_count,
       case when sum(l.total_count) > 0 then round((sum(coalesce(l.rating, 0) * l.total_count) / sum(l.total_count))::numeric, 2) end as rating,
       count(*)::int as listing_count,
       max(l.fetched_on) as fetched_on
from d
join lateral (
  select distinct on (s.listing_id) s.listing_id, s.total_count, s.rating, s.fetched_on
  from public.google_review_snapshots s join public.google_place_listings m on m.id = s.listing_id
  where s.store_id = d.store_id and s.as_of_date <= d.as_of_date and m.status not in ('inactive', 'invalid')
  order by s.listing_id, s.as_of_date desc
) l on true
group by d.store_id, d.as_of_date;
grant select on public.google_review_store_daily_v to authenticated;

-- 今日(JST)時点の店舗別 KPI（ダッシュボード・AI窓口向け）
create or replace view public.google_review_kpi_v as
select s.id as store_id, s.name as store_name, k.*
from public.stores s
join lateral (
  select (j->>'total')::int as total_count, (j->>'rating')::numeric as rating, (j->>'as_of_date')::date as as_of_date,
         (j->>'fetched_on')::date as fetched_on, (j->>'listing_count')::int as listing_count,
         (j->>'day_inc')::int as day_inc, (j->>'week_inc')::int as week_inc, (j->>'month_inc')::int as month_inc,
         j->'listings' as listings
  from public.google_review_store_kpi(s.id, (now() at time zone 'Asia/Tokyo')::date) j
) k on true
where k.listing_count > 0;
grant select on public.google_review_kpi_v to authenticated;

-- 旧新比較（並行稼働の検証用）: 同じ掲載・同じ取得日の 新(Places API 直結) と 旧(シート鏡) を並べる
create or replace view public.google_review_legacy_compare_v as
select st.name as store_name, m.listing_name, n.fetched_on,
       n.total_count as new_total, l.total_count as old_total, n.total_count - l.total_count as total_diff,
       n.rating as new_rating, l.avg_star as old_rating, round((n.rating - l.avg_star)::numeric, 2) as rating_diff,
       n.google_display_name as new_google_name, l.google_name as old_google_name
from public.google_review_snapshots n
join public.google_place_listings m on m.id = n.listing_id
join public.stores st on st.id = m.store_id
join public.kd_google_review_listings l on l.store_id = m.store_id and l.listing_name = m.listing_name and l.fetched_on = n.fetched_on
where n.source = 'places_api';
grant select on public.google_review_legacy_compare_v to authenticated;

-- 6) daily_report_card_vm v5（口コミを新正本から。v4 との違い: 看板 CTE → google_review_store_kpi()、基準日=取得日−1、greatest(0,…) 廃止、
--    week/day の増加キーを追加。他のキーは v4 と同じ）
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
-- Google 口コミ（v5・2026-11-06）: 新正本 google_review_snapshots を google_review_store_kpi() で集計
--   基準日 = 取得日の前日（経営ダッシュボードと同じ）。月間増加 = 当日以前の最新 − 月初より前の最新。マイナスはそのまま（0 に丸めない）
gr as (select public.google_review_store_kpi(p.sid, p.dt) as k from p)
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
  'google_review_total', (select (k->>'total')::int from gr),
  'google_review_avg_star', (select (k->>'rating')::numeric from gr),
  'google_review_updated_at', (select (k->>'fetched_on')::date from gr),
  'google_review_as_of_date', (select (k->>'as_of_date')::date from gr),
  'google_review_month_increase', (select (k->>'month_inc')::int from gr),
  'google_review_week_increase', (select (k->>'week_inc')::int from gr),
  'google_review_day_increase', (select (k->>'day_inc')::int from gr),
  'mtd_review_count', (select (k->>'month_inc')::int from gr),
  -- 看板（Google掲載）ごとの内訳: 2看板以上の店舗で画像に表示（label=短い表示名・month_increase は起点が無ければ null → 画像は「—件」）
  'google_review_listings', coalesce((select jsonb_agg(jsonb_build_object('name', l->>'name', 'label', l->>'label', 'total', (l->>'total')::int, 'month_increase', (l->>'month_inc')::int, 'updated_at', (l->>'fetched_on')::date)) from gr, jsonb_array_elements(k->'listings') l), '[]'::jsonb),
  'google_review_listing_count', (select (k->>'listing_count')::int from gr),
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
