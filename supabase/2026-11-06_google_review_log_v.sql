-- =============================================================
-- Google口コミ Supabase直結化 ③（2026-11-06）: 経営ダッシュボードの口コミタブを Supabase 直読みにするための View
--   ダッシュボード GAS（getData の key='review'）がシート「口コミ推移ログ」の代わりにこの View を読む。
--   列は旧シートと同じ 8 列（取得日・店舗名・累計口コミ数・平均星・前回比・Google名称・住所・取得元）。GAS 側でヘッダーを旧シートと同じ「前回比(増加)」にして返すので app.js は無変更。
--   （列名に括弧を入れると PostgREST の select で埋め込み構文と解釈されるため、View の列名は「前回比」）
--   「店舗名」= 掲載名（listing_name。黒霧屋 新横浜／うお蔵 新横浜／カラオケ 彩-… など）＝ 旧シートと同じ表記 → REVIEW_CHILDREN/aliases の紐付けがそのまま効く。
--   前回比 = 同じ掲載の 1 つ前のスナップショットとの差（マイナスもそのまま）。
--   公開データ（Google 上の件数・星）なので store_directory_v と同じく anon キーで読める（GAS に秘密を置かない）。
--   適用: python3 scripts/apply_sql.py supabase/2026-11-06_google_review_log_v.sql
-- =============================================================
drop view if exists public.google_review_log_v;
create view public.google_review_log_v as
select to_char(s.fetched_on, 'YYYY/MM/DD') as "取得日",
       m.listing_name                        as "店舗名",
       s.total_count                          as "累計口コミ数",
       s.rating                               as "平均星",
       s.total_count - lag(s.total_count) over (partition by s.listing_id order by s.fetched_on) as "前回比",
       coalesce(s.google_display_name, m.google_display_name) as "Google名称",
       m.google_address                       as "住所",
       case s.source when 'places_api' then 'API自動(Supabase)' else '旧シート引継' end as "取得元",
       s.fetched_on, st.name as store_name, s.listing_id
from public.google_review_snapshots s
join public.google_place_listings m on m.id = s.listing_id
join public.stores st on st.id = m.store_id
where m.status not in ('inactive', 'invalid');
grant select on public.google_review_log_v to anon, authenticated;
