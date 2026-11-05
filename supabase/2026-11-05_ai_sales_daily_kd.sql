-- =============================================================
-- AI窓口（Hermes/ai-gateway）の sales_daily を kd_daily_store_full ベースに変更（2026-11-05）
-- 症状: Slack/LINE で「昨日の店舗別売上」を聞くと全店 0 円（2026-11-05 ユーザー報告）。
-- 原因: ai_sales_daily が読む dash_sales_daily は毎日 14:00 JST に 1 回だけ同期され、それまで前日の sales が 0。
--       しかも 8 店分しか入らない日がある。一方 kd_daily_store_full（keiei-kd-refresh）は 12:00 JST に更新され 12 店そろい、
--       前年同曜日（prior_year_same_weekday_sales）も持つ。11/03 で両表の売上は店舗別に完全一致。
-- 変更: 主系を kd_daily_store_full にし、その日の行が無ければ従来どおり dash_sales_daily を使う。出力の形（JSON のキー）は同じ。
-- 適用: python3 scripts/apply_sql.py supabase/2026-11-05_ai_sales_daily_kd.sql   （--dry-run で空振り可）
-- 戻し方: supabase/restored/2026-11-05_ai_sales_daily_prod_snapshot.sql を適用
-- =============================================================
CREATE OR REPLACE FUNCTION public.ai_sales_daily(p_date date DEFAULT NULL::date, p_store text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with d as (select coalesce(p_date, (now() at time zone 'Asia/Tokyo')::date - 1) as dt),
  has_kd as (select exists(select 1 from kd_daily_store_full k, d where k.date = d.dt and coalesce(k.net_sales,0) > 0) as ok),
  cur as (
    -- 主系: kd_daily_store_full（12:00 更新・12 店・前年同曜日つき）
    select s.store_no, s.name, k.net_sales as sales, k.cogs as cost, k.labor_cost_total as labor,
           k.prior_year_same_weekday_sales as ly_sales, 'kd_daily_store_full' as src
    from kd_daily_store_full k join stores s on s.id = k.store_id, d, has_kd
    where has_kd.ok and k.date = d.dt
      and (p_store is null or s.name like '%'||p_store||'%' or s.store_no = p_store)
    union all
    -- 予備: dash_sales_daily（14:00 同期・従来の経路）
    select s.store_no, s.name, x.sales, x.cost, x.labor,
           (select y.sales from dash_sales_daily y where y.store_id = x.store_id and y.biz_date = d.dt - interval '364 days') as ly_sales,
           'dash_sales_daily' as src
    from dash_sales_daily x join stores s on s.id = x.store_id, d, has_kd
    where not has_kd.ok and x.biz_date = d.dt
      and (p_store is null or s.name like '%'||p_store||'%' or s.store_no = p_store)
  )
  select jsonb_build_object(
    'date', (select dt from d),
    'weekday', to_char((select dt from d), 'Dy'),
    'source', (select max(src) from cur),
    'note', '金額は円。last_year_same_weekday=前年の同じ曜日（364日前）。主系は経営ダッシュボードの日次集計（毎日12:00更新・12店）。前年が無い店は null',
    'total_sales', (select coalesce(sum(sales),0) from cur),
    'last_year_same_weekday_total', (select coalesce(sum(ly_sales),0) from cur),
    'by_store', (select coalesce(jsonb_agg(jsonb_build_object('store_no', c.store_no, 'store', c.name, 'sales', c.sales, 'cost', c.cost, 'labor', round(c.labor),
                        'last_year_same_weekday', c.ly_sales) order by c.store_no nulls last, c.name), '[]'::jsonb)
                 from cur c)
  );
$function$;
