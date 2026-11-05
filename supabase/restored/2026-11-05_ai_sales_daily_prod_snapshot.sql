-- 本番 ai_sales_daily の復元スナップショット（2026-11-05・変更前）。マイグレーションではない。戻すときはこれを再適用。
CREATE OR REPLACE FUNCTION public.ai_sales_daily(p_date date DEFAULT NULL::date, p_store text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with d as (select coalesce(p_date, (now() at time zone 'Asia/Tokyo')::date - 1) as dt),
  cur as (
    select s.store_no, s.name, x.sales, x.cost, x.labor
    from dash_sales_daily x join stores s on s.id = x.store_id, d
    where x.biz_date = d.dt and (p_store is null or s.name like '%'||p_store||'%' or s.store_no = p_store)
  ),
  ly as (
    select s.store_no, x.sales
    from dash_sales_daily x join stores s on s.id = x.store_id, d
    where x.biz_date = d.dt - interval '364 days'  -- 前年の同じ曜日
  )
  select jsonb_build_object(
    'date', (select dt from d),
    'weekday', to_char((select dt from d), 'Dy'),
    'total_sales', (select coalesce(sum(sales),0) from cur),
    'last_year_same_weekday_total', (select coalesce(sum(sales),0) from ly),
    'by_store', (select coalesce(jsonb_agg(jsonb_build_object('store_no', c.store_no, 'store', c.name, 'sales', c.sales, 'cost', c.cost, 'labor', round(c.labor),
                        'last_year_same_weekday', l.sales) order by c.store_no), '[]'::jsonb)
                 from cur c left join ly l on l.store_no = c.store_no)
  );
$function$
;
