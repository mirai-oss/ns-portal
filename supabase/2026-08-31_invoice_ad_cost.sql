-- 請求書 → 広告費の自動反映（C-7②・2026-08-31）
-- 設計書_広告費自動連携と精算書PL科目連携_2026-08-31.md §4の確定仕様どおり。
-- invoicesテーブルに列追加のみ（既存の2026-08-23_invoices.sqlは触らない・新規日付ファイルで追記する方針）
alter table invoices add column if not exists ad_cost_media text;                    -- 正規化後の媒体名（例: 食べログ）
alter table invoices add column if not exists ad_cost_year_month date;               -- 対象年月（月初日で保存。例: 2026-08-01）
alter table invoices add column if not exists ad_cost_allocations jsonb;             -- [{store_id, store_name, amount, source}]
alter table invoices add column if not exists ad_cost_reflected_at timestamptz;      -- 確定した時刻（この列があれば重複反映を防ぐ）
alter table invoices add column if not exists ad_cost_reflected_by uuid references users(id);
alter table invoices add column if not exists ad_cost_sheet_synced_at timestamptz;   -- 広告費用対効果_管理シート＋BQへの実際の書き込みが成功した時刻
alter table invoices add column if not exists ad_cost_sheet_sync_error text;         -- GAS書き込みaction未実装・失敗時のメッセージ（A-8完了までは常にここにエラーが入る想定）
