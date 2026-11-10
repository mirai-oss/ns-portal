-- 2026-11-11 担当A: F/L/FL 数値一致の確認（読み取り専用・参照側デプロイ後に実行）。service_role で実行すること（先頭の set local role）
-- 比較: ①共通定義 fl_metrics_month（正本）②月次サマリ kd_store_monthly_summary の fl_sales / cost_rate / labor_rate / fl_rate ③（画面確認用）同店・同月の期間合計
-- 期待: すべての店舗×月で diff が 0（許容 0.0005＝0.05pt）。デリバリーなし店は fl_sales = sales。月間は期間合計から算出（日次比率の平均ではない）。
set local role service_role;
with m as (select to_char(date_trunc('month', current_date) - (n || ' month')::interval, 'YYYY-MM') ym from generate_series(0, 1) n)
select s.name, m.ym,
  (f->>'fl_sales')::numeric as common_fl_sales, k.fl_sales as summary_fl_sales,
  round(((f->>'f_rate')::numeric - k.cost_rate)::numeric, 5) as diff_f, round(((f->>'l_rate')::numeric - k.labor_rate)::numeric, 5) as diff_l, round(((f->>'fl_ratio')::numeric - k.fl_rate)::numeric, 5) as diff_fl,
  k.sales as summary_sales, (f->>'instore_sales')::numeric as common_instore_sales,
  case when abs(coalesce((f->>'f_rate')::numeric - k.cost_rate, 0)) <= 0.0005 and abs(coalesce((f->>'l_rate')::numeric - k.labor_rate, 0)) <= 0.0005 and abs(coalesce((f->>'fl_ratio')::numeric - k.fl_rate, 0)) <= 0.0005 and k.sales = (f->>'instore_sales')::numeric then 'OK' else '要確認' end as result
from stores s cross join m
cross join lateral (select public.fl_metrics_month(s.id, m.ym) f) x
left join public.kd_store_monthly_summary k on k.store_id = s.id and k.year_month = m.ym
where s.is_active and k.store_id is not null
order by result desc, s.name, m.ym;
-- ※ 人件費の範囲差: 月次サマリの labor は dashboard日次の labor 合計＋スポット（本書の共通定義と同じ範囲）。仕入確定月（shiire_status=confirmed）は月次サマリの原価が請求書の仕入高に置換されるため、F率が共通定義（日次cogs合計）と差が出る場合は「確定月」として別扱い。
