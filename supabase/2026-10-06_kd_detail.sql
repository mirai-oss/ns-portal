-- レーンP: 明細分析(#5)のkd_化 — 商品日次・時間帯日次・デリバリー日次＋期間集計RPC（依頼_レーンP_経営D_F2用kd追加 #5・担当Aとの合意 2026-10-06）
--
-- 【事前報告様式（DB変更）】
-- 理由: 明細分析タブはGAS bqDetail（dinii.ordersをBigQueryで都度集計）で初回30秒〜1分かかる。ユーザー要件=期間は日/週/月/年/任意、
--       区分はランチ/ディナー/デリバリー、ランチ/ディナーの分析は必須、商品別ランキングとABCは期間可変（上位100固定では不足）。
-- 現構造: kd_にdinii明細の集計は無い。デリバリーはstg_delivery_order(BQ)に店舗×日の件数・売上のみ（商品はitems_textの文字列）。
-- 設計: 加算可能な最小粒度（店舗×営業日×区分×商品／店舗×営業日×区分×時間）をSupabaseに持ち、期間集計はRPCで返す
--       （ブラウザには全行を渡さない）。ランチ/ディナーの境目は現行bqDetailの判定をBQ側で適用した結果を受け取って保存するだけ
--       （計算式は1か所＝GAS。logic_verで計算式の版を保持し、変わったらPが該当期間を再取込）。
--       集計基準checkout（会計時）のみ対象（order/arrivalはGAS従来経路）。デリバリーは店舗×日の売上・件数のみ（商品別/ABC対象外）。
-- 既存データへの影響: 新規テーブル3本・関数4本のみ。既存の列・行・API返り値は不変。
-- migration: 本ファイル(何度流しても壊れない)。 rollback: 新規テーブル・関数のdrop（他から参照されない新規物）

create table if not exists public.kd_detail_item_daily (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id),
  biz_date date not null,
  daypart text not null check (daypart in ('lunch', 'dinner')),
  item_name text not null,
  category text,
  qty numeric not null default 0,
  sales_incl numeric not null default 0,
  sales_excl numeric not null default 0,
  logic_ver int,                                   -- 取込時のbqDetail計算式の版(BQ_DETAIL_LOGIC_VER)
  computed_at timestamptz not null default now(),
  sync_run_id uuid references public.kd_sync_runs (id)
);
create unique index if not exists kd_detail_item_daily_unique on public.kd_detail_item_daily (store_id, biz_date, daypart, item_name);
create index if not exists kd_detail_item_daily_date_idx on public.kd_detail_item_daily (biz_date, store_id);

create table if not exists public.kd_detail_hour_daily (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id),
  biz_date date not null,
  daypart text not null check (daypart in ('lunch', 'dinner')),
  hour int not null check (hour between 0 and 47),  -- 会計時刻の時（営業日をまたぐ深夜は24以上でも可。BQのEXTRACT(HOUR)は0〜23）
  sales_incl numeric not null default 0,
  sales_excl numeric not null default 0,
  checks int not null default 0,                   -- COUNT(DISTINCT check_id)。会計時刻基準なので日・時間・区分で加算可能
  guests_otoshi numeric not null default 0,        -- お通し注文数量（bqDetailの客数推定の元）
  qty numeric not null default 0,
  drink_excl numeric not null default 0,
  food_excl numeric not null default 0,
  karaoke_excl numeric not null default 0,
  logic_ver int,
  computed_at timestamptz not null default now(),
  sync_run_id uuid references public.kd_sync_runs (id)
);
create unique index if not exists kd_detail_hour_daily_unique on public.kd_detail_hour_daily (store_id, biz_date, daypart, hour);
create index if not exists kd_detail_hour_daily_date_idx on public.kd_detail_hour_daily (biz_date, store_id);

create table if not exists public.kd_delivery_daily (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id),
  biz_date date not null,
  channel text not null default 'ロケットナウ',
  orders int not null default 0,
  net_sales numeric not null default 0,
  computed_at timestamptz not null default now(),
  sync_run_id uuid references public.kd_sync_runs (id)
);
create unique index if not exists kd_delivery_daily_unique on public.kd_delivery_daily (store_id, biz_date, channel);
create index if not exists kd_delivery_daily_date_idx on public.kd_delivery_daily (biz_date, store_id);

-- RLS: 既存のkd_と同じ（CEO/HQ/TEAM/マスターは全店・店長は自店舗のみ）
do $$
declare t text;
begin
  foreach t in array array['kd_detail_item_daily', 'kd_detail_hour_daily', 'kd_delivery_daily'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format($p$create policy %I on public.%I for select to authenticated using (
      exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (
        u.is_master or u.role in ('CEO', 'HQ', 'TEAM')
        or (u.role = 'TENCHO' and exists (select 1 from public.user_stores us where us.user_id = u.id and us.store_id = %I.store_id))
      ))
    )$p$, t || '_select', t, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 期間集計RPC（Edge Function(service_role)からだけ呼ぶ。店舗スコープはAPI側で判定済みのp_storesを渡す）
-- p_daypart: 'all' | 'lunch' | 'dinner'。p_basis: 'incl'(税込) | 'excl'(税別)
-- ---------------------------------------------------------------------
create or replace function public.kd_detail_items(p_from date, p_to date, p_stores uuid[], p_daypart text default 'all', p_basis text default 'incl', p_limit int default 3000)
returns table (item_name text, category text, qty numeric, sales_incl numeric, sales_excl numeric, rank int, share numeric, cum_share numeric, total_sales numeric)
language sql stable security invoker set search_path = public as $$
  with agg as (
    select i.item_name, max(i.category) as category, sum(i.qty) as qty, sum(i.sales_incl) as sales_incl, sum(i.sales_excl) as sales_excl,
           case when p_basis = 'excl' then sum(i.sales_excl) else sum(i.sales_incl) end as m
    from public.kd_detail_item_daily i
    where i.biz_date between p_from and p_to and i.store_id = any(p_stores) and (p_daypart = 'all' or i.daypart = p_daypart)
    group by i.item_name
  ), tot as (select nullif(sum(m), 0) as t from agg)
  select a.item_name, a.category, a.qty, a.sales_incl, a.sales_excl,
         (row_number() over (order by a.m desc, a.item_name))::int as rank,
         a.m / tot.t as share,
         sum(a.m) over (order by a.m desc, a.item_name rows between unbounded preceding and current row) / tot.t as cum_share,
         tot.t as total_sales
  from agg a cross join tot
  order by a.m desc, a.item_name
  limit greatest(1, least(p_limit, 5000));
$$;

create or replace function public.kd_detail_hours(p_from date, p_to date, p_stores uuid[], p_daypart text default 'all')
returns table (hour int, sales_incl numeric, sales_excl numeric, checks bigint, guests_otoshi numeric, qty numeric)
language sql stable security invoker set search_path = public as $$
  select h.hour, sum(h.sales_incl), sum(h.sales_excl), sum(h.checks)::bigint, sum(h.guests_otoshi), sum(h.qty)
  from public.kd_detail_hour_daily h
  where h.biz_date between p_from and p_to and h.store_id = any(p_stores) and (p_daypart = 'all' or h.daypart = p_daypart)
  group by h.hour order by h.hour;
$$;

create or replace function public.kd_detail_stores(p_from date, p_to date, p_stores uuid[], p_daypart text default 'all')
returns table (store_id uuid, sales_incl numeric, sales_excl numeric, checks bigint, guests_otoshi numeric, drink_excl numeric, food_excl numeric, karaoke_excl numeric)
language sql stable security invoker set search_path = public as $$
  select h.store_id, sum(h.sales_incl), sum(h.sales_excl), sum(h.checks)::bigint, sum(h.guests_otoshi), sum(h.drink_excl), sum(h.food_excl), sum(h.karaoke_excl)
  from public.kd_detail_hour_daily h
  where h.biz_date between p_from and p_to and h.store_id = any(p_stores) and (p_daypart = 'all' or h.daypart = p_daypart)
  group by h.store_id order by sum(h.sales_incl) desc;
$$;

-- 取込カバレッジ（月×店舗数×営業日数×商品行数）。薄い月＝取りこぼし/導入前の発見用（現行「明細カバレッジ」相当）
create or replace function public.kd_detail_coverage(p_from date, p_to date, p_stores uuid[])
returns table (month text, stores bigint, days bigint, item_rows bigint)
language sql stable security invoker set search_path = public as $$
  select to_char(i.biz_date, 'YYYY-MM'), count(distinct i.store_id), count(distinct i.biz_date), count(*)
  from public.kd_detail_item_daily i
  where i.biz_date between p_from and p_to and i.store_id = any(p_stores)
  group by 1 order by 1;
$$;

revoke all on function public.kd_detail_items(date, date, uuid[], text, text, int) from public, anon, authenticated;
revoke all on function public.kd_detail_hours(date, date, uuid[], text) from public, anon, authenticated;
revoke all on function public.kd_detail_stores(date, date, uuid[], text) from public, anon, authenticated;
revoke all on function public.kd_detail_coverage(date, date, uuid[]) from public, anon, authenticated;
grant execute on function public.kd_detail_items(date, date, uuid[], text, text, int) to service_role;
grant execute on function public.kd_detail_hours(date, date, uuid[], text) to service_role;
grant execute on function public.kd_detail_stores(date, date, uuid[], text) to service_role;
grant execute on function public.kd_detail_coverage(date, date, uuid[]) to service_role;
