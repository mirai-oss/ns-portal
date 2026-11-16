-- 2026-11-08: Hermes(AI窓口)にGoogle口コミのビューを許可
-- 経緯: 11/6に新設された口コミ関連テーブル/ビューはai_table_policyに未登録のため
-- ai_reader_sync()が「未判定=拒否」として扱っていた（google_review_log_v等が読めない）。
-- 中身は公開情報（件数・星）のため機密性の問題はない。

insert into ai_table_policy(table_name, allowed, description) values
  ('google_review_log_v', true, 'Google口コミ推移ログ（取得日・店舗名・累計口コミ数・平均星・前回比・取得元）'),
  ('google_review_snapshots', true, '店舗×日のGoogle口コミ件数・平均星のスナップショット（正本）'),
  ('google_place_listings', true, 'Google掲載マスタ（店舗×掲載名・place_id）'),
  ('google_review_kpi_v', true, 'Google口コミKPI集計ビュー'),
  ('google_review_store_daily_v', true, 'Google口コミ店舗×日次集計ビュー')
on conflict (table_name) do update set allowed = true, description = excluded.description, updated_at = now();

select * from ai_reader_sync() where table_name like 'google_review%';
