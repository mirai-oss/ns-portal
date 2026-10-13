-- 担当C: 請求書メール自動処理 Phase4「マッピング接続」— 明細行の店舗解決の記録用列
--
-- 【事前報告様式（DB変更）】
-- 理由: 明細の店舗表記を resolve_store（店舗マスタ正本の共通ゲートウェイ）で正式な店舗に結びつけた結果
--       （どの確からしさ・どの方法で決まったか、low候補など）を、行ごとに残す。
-- 現構造: invoice_lines は resolved_store_id / resolved_by のみ（Phase3で作成）。
-- 変更: invoice_lines に resolve_info jsonb を1列追加するだけ。既存の表・列・ポリシーは変更しない。
-- 既存データへの影響: なし。 migration: 何度流しても壊れない。 rollback: alter table invoice_lines drop column resolve_info;
alter table public.invoice_lines add column if not exists resolve_info jsonb;
