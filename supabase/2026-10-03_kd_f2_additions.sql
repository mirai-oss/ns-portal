-- レーンP: F2用kd_追加の第1弾（実装指示書_ラウンド6_2026-09-18.md §7 P②／設計書_経営D即時表示_GASレス起動 R8）
--
-- 【事前報告様式（DB変更）】
-- 理由: ①PL管理タブをkd_pl主経路にする(F1-b)と、画面下部の「簡易キャッシュフロー」(営業利益−法人税+減価償却−返済元金)の
--       返済元金がkd_に無く、CF欄が空になる／旧経路と数字がズレる。②予約分析の月×店舗表示は、日次(kd_reservation_daily_summary)
--       だけだと24か月分で約1万行になり「月切替は通信ゼロ・24か月を1回で取得」(R7)に向かない。
-- 現構造: kd_pl_monthly_summaryに返済元金の列は無い(v1の既知の制約②)。予約は日次テーブルのみ。
-- 既存データへの影響: 列追加(null許容・既存行は無変更)とビュー新設のみ。既存の列・行・RLS・API返り値は変えない。
-- migration: 本ファイル(何度流しても壊れない)。 rollback: `alter table ... drop column loan_principal;` / `drop view kd_reservation_monthly_v;`
--       (どちらも他から参照されていない新規物のため即戻せる)

-- 1. kd_pl_monthly_summary.loan_principal: 借入返済元金(stg_loan_principal・GAS bqGetLoanPrincipal経由)の月合計。
--    store_id=null行(店舗名が空の全社共通行)には全社共通の元金が入る。app.jsのloanPrincipalAgg()と同じ定義で、
--    店舗単独表示では全社共通を含めない運用は画面側が決める(PL経費のstore_id=null行と同じ扱い)。
alter table public.kd_pl_monthly_summary add column if not exists loan_principal numeric;
comment on column public.kd_pl_monthly_summary.loan_principal is
  '借入返済元金(月合計)。stg_loan_principal由来。PL費用ではない(営業利益に含めない)。簡易CF=営業利益−税+減価償却(pl_item_breakdownのO区分「減価償却費」)−本列。store_id=null行は全社共通分';

-- 2. 予約の月次ビュー: kd_reservation_daily_summaryを店舗×月に集計(リフレッシュ不要=常に日次と一致)。
--    security_invoker=trueで元テーブルのRLS(CEO/HQ/TEAM/マスターは全店・店長は自店舗)がそのまま効く。
create or replace view public.kd_reservation_monthly_v with (security_invoker = true) as
select
  store_id,
  corporation_id,
  to_char(period_date, 'YYYY-MM') as year_month,
  sum(reservation_count)::int  as reservation_count,
  sum(party_size_sum)::int     as party_size_sum,
  sum(same_day_count)::int     as same_day_count,
  sum(same_day_party)::int     as same_day_party,
  sum(walkin_count)::int       as walkin_count,
  sum(walkin_party)::int       as walkin_party,
  sum(expected_sales)          as expected_sales,
  count(*)::int                as days_with_data,
  max(computed_at)             as computed_at
from public.kd_reservation_daily_summary
group by store_id, corporation_id, to_char(period_date, 'YYYY-MM');
comment on view public.kd_reservation_monthly_v is
  '予約の店舗×月集計(kd_reservation_daily_summaryのビュー)。キャンセル内訳・チャネル内訳(jsonb)は日次側のcancel_summaryモードを使う。';

-- 3. kd_store_monthly_summary.labor_other: 人件費合計(labor_cost_total)のうちPA・社員の内訳に入らない分（残差）。
--    【事前報告】理由: app.jsのstat()の人件費合計は fact_daily_store.labor_cost_total(+スポット) であり、PA+社員の和ではない。
--    API切替前の月(〜2026-08)は labor_cost_total が社員賞与・法定福利・通勤手当等を含み、PA+社員の和の2倍超になる月がある
--    (2026-06実測)。当初のlabor_total=PA+社員+スポットでは旧経路よりL率が低く出ていた。
--    現構造: labor_pa/labor_emp/labor_spot/labor_total(=3つの和)。 影響: 列追加(null許容)＋labor_totalの定義を
--    labor_cost_total+スポットへ修正(リフレッシュで全行が再計算される)。 rollback: 列drop＋コードを戻す。
alter table public.kd_store_monthly_summary add column if not exists labor_other numeric;
comment on column public.kd_store_monthly_summary.labor_other is 'labor_cost_total−(labor_pa+labor_emp)。社員賞与・法定福利・通勤手当等のPA/社員内訳外。labor_total=labor_cost_total合計+labor_spot';
