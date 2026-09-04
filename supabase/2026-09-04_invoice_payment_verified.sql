-- 支払確認済み（payment_verified）の記録用列（2026-09-04・指示書②③のpayment_verifiedイベント対応）
-- 既存のpayment_status（not_ready/wait/csv/processing/paid/blocked）に新しい値を増やすと
-- 既存の判定ロジック（PAYMENT_STATUS_LABEL等）に影響が広いため、別列として独立させる。
-- 「振込済み（paid）」とは別に、実際に着金・支払完了を確認できた時点でセットする
alter table invoices add column if not exists payment_verified_at timestamptz;
alter table invoices add column if not exists payment_verified_by uuid references users(id);
