-- マネーフォワード複数事業者（テナント）対応（2026-08-27）
-- 1事業者=1行だったmf_oauth_tokensを複数事業者対応にする。既存の'default'行（有限会社トーホーエージェンシー）は
-- そのまま維持し、新規事業者（株式会社N-Style等）は別idの行として追加していく。
alter table mf_oauth_tokens add column if not exists label text;
update mf_oauth_tokens set label = '有限会社トーホーエージェンシー' where id = 'default' and label is null;

-- どの事業者（テナント）に仕訳登録したかを記録（invoice_audit_logs等での追跡・将来の一覧表示用）
alter table invoices add column if not exists mf_tenant_id text;
