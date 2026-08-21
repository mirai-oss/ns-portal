-- =====================================================================
-- 本部（HQ）を stores に登録 — データ基盤Day3 バックフィル中に判明したギャップ対応
-- =====================================================================
-- 背景: スマレジ勤怠実績の90日バックフィルで smaregi_store_id=7 が
--   16件「store未対応」エラーになっていた。調査の結果、shiftDaily応答の
--   storeName フィールドから「本部」であることが判明（本部所属スタッフの
--   打刻先。小売店舗ではないため、これまで stores テーブルに存在しなかった）。
--
-- 対応: 「本部」を is_active=false の特殊な店舗行として追加する
--   （通常の店舗一覧（is_active=trueで回すUI）には出てこないが、
--   attendance_records/labor_cost_daily のstore_id外部キーとしては解決できる）。
-- 実行場所: Supabase SQL Editor / Management API（何度実行しても壊れません）
-- =====================================================================

insert into stores (name, sort_order, is_active, smaregi_store_id, store_no)
select '本部', 99, false, '7', '99'
where not exists (select 1 from stores where smaregi_store_id = '7');
