-- 2026-11-11 担当A: F/L/FL 変更前後の店舗別比較（読み取り専用SELECT・本番で実行してよい）。直近3か月×有効店舗
-- 列: before=現行（店内売上のみで割る＝日報VM v5・kd_store_monthly_summary と同じ）／mixed=経営Dのメインkpi現行（店内＋デリバリー税込のまま）／after=新共通定義（店内＋デリバリー÷1.08）
-- 検証: has_delivery=false の行は before=mixed=after（差0）であること。
with months as (select to_char(date_trunc('month', current_date) - (n || ' month')::interval, 'YYYY-MM') ym from generate_series(0, 2) n),
base as (
  select s.id store_id, s.name, m.ym,
    (select coalesce(sum(k.net_sales),0) from kd_daily_store_full k where k.store_id = s.id and to_char(k.date,'YYYY-MM') = m.ym) instore,
    (select coalesce(sum(k.labor_cost_total),0) from kd_daily_store_full k where k.store_id = s.id and to_char(k.date,'YYYY-MM') = m.ym)
      + (select coalesce(sum(e.amount),0) from kd_spot_entries e where e.store_id = s.id and to_char(e.work_date,'YYYY-MM') = m.ym) labor,
    (select coalesce(sum(k.cogs),0) from kd_daily_store_full k where k.store_id = s.id and to_char(k.date,'YYYY-MM') = m.ym) cost,
    (select coalesce(sum(d.net_sales),0) from kd_delivery_daily d where d.store_id = s.id and to_char(d.biz_date,'YYYY-MM') = m.ym) dgross
  from stores s cross join months m where s.is_active
)
select name, ym, (dgross <> 0) has_delivery, instore::bigint, dgross::bigint delivery_gross, round(dgross / public_fl_div.d)::bigint delivery_ex,
  round((labor / nullif(instore,0))::numeric * 100, 2) l_before, round((labor / nullif(instore + dgross,0))::numeric * 100, 2) l_mixed, round((labor / nullif(instore + dgross / public_fl_div.d,0))::numeric * 100, 2) l_after,
  round((cost / nullif(instore,0))::numeric * 100, 2) f_before, round((cost / nullif(instore + dgross,0))::numeric * 100, 2) f_mixed, round((cost / nullif(instore + dgross / public_fl_div.d,0))::numeric * 100, 2) f_after,
  round(((labor + cost) / nullif(instore,0))::numeric * 100, 2) fl_before, round(((labor + cost) / nullif(instore + dgross,0))::numeric * 100, 2) fl_mixed, round(((labor + cost) / nullif(instore + dgross / public_fl_div.d,0))::numeric * 100, 2) fl_after
from base, (select 1.08::numeric d) public_fl_div   -- ※関数適用前でも動くよう換算率を直接書いている（適用後は fl_delivery_tax_divisor() と同じ値）
where instore <> 0 or dgross <> 0
order by name, ym;
