-- 担当C: 請求書メール自動処理 Phase5「仕訳下書き」（実装指示書 Phase5／設計書§9-1）
--
-- 【事前報告様式（DB変更）】
-- 理由: 明細行（Phase3）・店舗の解決結果（Phase4）・取引先×明細の行ルール（vendor_line_rules）から、
--       MFに登録する前の「仕訳の下書き」を請求書ごとに作って持つ。承認画面（Phase7）はこれを見て承認する。
-- 現構造: invoices に仕訳の下書きを持つ列は無い（mf_debit_accounts は登録後の記録のみ）。
-- 変更: invoices に journal_draft（jsonb）と journal_draft_at（作成日時）を追加するだけ。既存の表・列・ポリシーは変更しない。
--   journal_draft には 法人・MF事業者・計上日・摘要・借方行（科目/補助/部門/税区分/金額/出どころのルールと版）・貸方・
--   1円調整・問題点（要確認の理由）・status(ok/needs_review) を入れる。MFのID（科目ID等）は承認時(Phase8)に名前から解決する。
-- 既存データへの影響: なし。 migration: 何度流しても壊れない。
-- rollback: alter table invoices drop column journal_draft, drop column journal_draft_at;
alter table public.invoices
  add column if not exists journal_draft jsonb,
  add column if not exists journal_draft_at timestamptz;
