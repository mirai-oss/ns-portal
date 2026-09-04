-- マネーフォワード登録エラーの記録用列（2026-09-04・会計ダッシュボード「MFエラー」カード対応）
-- 従来、mf-journalのcreateアクションが失敗してもエラー内容はmf_sync_logsに記録されるだけで、
-- invoices側には何も残らず、一覧・ダッシュボードから「どの請求書がMF登録に失敗しているか」を
-- 判別する手段が無かった（会計ダッシュボード指示書§3「取得できない数字を推測しない」の
-- 対応として、無いものは無いと正直に扱うのではなく、最小限の追加実装で解消する）
alter table invoices add column if not exists mf_registration_error text;
alter table invoices add column if not exists mf_registration_error_at timestamptz;
