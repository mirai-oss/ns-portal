-- 2026-11-11 担当A: 売上内訳（営業区分別売上）の比較表（読み取り専用・直近31日×店舗×営業日）。TK-252 B調査
-- 列: pos=POS確定売上(kd_dashboard_daily_summary.net_sales) / media_lunch=営業区分「ランチ」(kd_media_daily のうち媒体名が ランチ|昼) / media_dinner=それ以外(=POS-ランチ。デリバリーは含まない)
--     ld_sum=L+D / ld_diff=L+D-POS / old_alloc_lunch=旧按分値(明細の時間帯比率でPOSを按分したランチ) / lunch_vs_old=media_lunch-old_alloc_lunch
--     delivery_rocketnow=kd_delivery_daily(ロケットナウ・税込のまま) / delivery_ex=÷1.08 / fl_sales=POS+delivery_ex
-- ※ 営業区分の分類は app.js mediaClassOf と同じ既定ルール（DB_媒体分類シートの上書き設定はDBに無いため未反映）
with pos as (select store_id, period_date d, net_sales pos from kd_dashboard_daily_summary where period_date >= current_date - 31 and period_date < current_date),
med as (select store_id, biz_date d, sum(net_sales) mt, sum(case when coalesce(media_raw,media_name) ~ 'ランチ|昼' then net_sales else 0 end) ml,
        sum(case when coalesce(media_raw,media_name) ~ 'デリバリ|ロケットナウ|出前' then net_sales else 0 end) mdel from kd_media_daily where biz_date >= current_date - 31 group by 1,2),
det as (select store_id, biz_date d, sum(case when daypart='lunch' then sales_excl else 0 end) dl, sum(case when daypart='dinner' then sales_excl else 0 end) dd from kd_detail_hour_daily where biz_date >= current_date - 31 group by 1,2),
dv as (select store_id, biz_date d, sum(net_sales) rn from kd_delivery_daily where biz_date >= current_date - 31 and channel = 'ロケットナウ' group by 1,2)
select s.name, pos.d, round(pos.pos) pos, round(med.ml) media_lunch, round(med.mt - med.ml) media_dinner, round(med.mt) ld_sum, round(med.mt - pos.pos) ld_diff,
  round(case when det.dl+det.dd > 0 then pos.pos * det.dl / (det.dl+det.dd) end) old_alloc_lunch,
  round(med.ml - case when det.dl+det.dd > 0 then pos.pos * det.dl / (det.dl+det.dd) end) lunch_vs_old,
  round(coalesce(dv.rn,0)) delivery_rocketnow, 0 delivery_ubereats_unlinked, round(coalesce(dv.rn,0)/1.08) delivery_ex, round(pos.pos + coalesce(dv.rn,0)/1.08) fl_sales
from pos join stores s on s.id = pos.store_id left join med on med.store_id = pos.store_id and med.d = pos.d left join det on det.store_id = pos.store_id and det.d = pos.d left join dv on dv.store_id = pos.store_id and dv.d = pos.d
where pos.pos > 0 order by s.name, pos.d;
