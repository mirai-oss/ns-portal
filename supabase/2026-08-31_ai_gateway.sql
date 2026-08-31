-- ============================================================
-- AI窓口（D-8 Hermes試用）フェーズC-1: 読み取り専用データ経路の監査ログ
-- 要件定義書§18準拠。書き込みはEdge Function（service role）のみ。
-- 冪等。
-- ============================================================
create table if not exists ai_audit_logs (
  id bigint generated always as identity primary key,
  called_at timestamptz not null default now(),
  agent text not null default 'hermes-line',
  query_key text not null,
  params jsonb,
  row_count int,
  ok boolean not null default true,
  error text
);
create index if not exists ai_audit_logs_called_idx on ai_audit_logs (called_at desc);

alter table ai_audit_logs enable row level security;
-- 読み: マスターのみ（ポータルから閲覧予定）。書き: ポリシー無し=service roleのみ
drop policy if exists ai_audit_read on ai_audit_logs;
create policy ai_audit_read on ai_audit_logs for select using (portal_is_master());

-- 売上サマリーRPC（PostgRESTの行数上限を回避しDB側で集計。実行はservice_roleのみ）
create or replace function ai_sales_summary(p_store text default null)
returns jsonb language sql stable security definer set search_path = public as $$
with t as (select (now() at time zone 'Asia/Tokyo')::date as today),
base as (
  select d.biz_date, d.sales, s.name
  from dash_sales_daily d join stores s on s.id = d.store_id, t
  where d.biz_date >= (date_trunc('month', t.today) - interval '23 months')::date
    and (p_store is null or s.name ilike '%'||p_store||'%')
)
select jsonb_build_object(
  'today', (select today from t),
  'this_month_total', coalesce((select round(sum(sales)) from base, t
     where biz_date >= date_trunc('month', today)::date and biz_date <= today), 0),
  'last_year_same_period', coalesce((select round(sum(sales)) from base, t
     where biz_date >= (date_trunc('month', today) - interval '1 year')::date
       and biz_date <= (today - interval '1 year')::date), 0),
  'monthly_trend', (select coalesce(jsonb_agg(jsonb_build_object('month', ym, 'sales', s) order by ym), '[]'::jsonb)
     from (select to_char(biz_date, 'YYYY-MM') ym, round(sum(sales)) s from base group by 1) m),
  'this_month_by_store', (select coalesce(jsonb_agg(jsonb_build_object('store', name, 'sales', s) order by s desc), '[]'::jsonb)
     from (select name, round(sum(sales)) s from base, t
           where biz_date >= date_trunc('month', today)::date group by name) b)
);
$$;
revoke all on function ai_sales_summary(text) from public, anon, authenticated;
