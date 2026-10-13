-- 担当C: 請求書メール自動処理 Phase2「invoice自動生成」（実装指示書 Phase2／設計書§10 二重処理防止）
--
-- 【事前報告様式（DB変更）】
-- 理由: 自動分類(Phase1)で「請求書（添付あり）」と判定されたメールの添付をAIで読み取り、下書きinvoiceを自動で作る。
--       同じ添付を再処理しない・同じ請求書が2つできない（入口が違っても1件に集約）ための印を持つ。
-- 現構造: invoices は email_id（メール1通につき1請求書＝unique）・attachment_id・intake_source を持つが、
--         元メッセージID・受信日時・読み取り結果・業務キーは持たない。invoice_attachments に「読み取り済み」の印は無い。
-- 変更（追加のみ。既存列の改名・意味変更なし）:
--   invoices に source_message_id / source_attachment_id / received_at / auto_ocr(読み取り結果jsonb。Phase6の振込先照合等で使う) / biz_key を追加
--   invoices.intake_source の許可値に 'email_auto' を追加（既存の許可値はそのまま）
--   invoices に 業務キー(biz_key)の部分ユニーク索引: 自動生成(intake_source='email_auto')で取消でない行は同じ業務キーを1件だけ
--      業務キー = 取引先ID×請求番号（無ければ 取引先ID×支払期限×税込合計）
--   invoice_attachments に ocr_done_at（読み取り済み。同じ添付を再処理しない）
--   invoice_emails に auto_invoice_at / auto_invoice_note（自動生成の実施日時と結果メモ）
-- 既存データへの影響: なし（既存行は新しい列がNULLのまま。既存の請求書・メールは変更しない）。
-- migration: 本ファイル（何度流しても壊れない）。
-- rollback: drop index invoices_biz_key_auto_uk; alter table invoices drop column biz_key, drop column auto_ocr, drop column received_at, drop column source_attachment_id, drop column source_message_id; alter table invoice_attachments drop column ocr_done_at; alter table invoice_emails drop column auto_invoice_at, drop column auto_invoice_note; （intake_source制約は元の6値へ戻す）

alter table public.invoices
  add column if not exists source_message_id text,
  add column if not exists source_attachment_id uuid references public.invoice_attachments(id) on delete set null,
  add column if not exists received_at timestamptz,
  add column if not exists auto_ocr jsonb,
  add column if not exists biz_key text;

alter table public.invoices drop constraint if exists invoices_intake_source_check;
alter table public.invoices add constraint invoices_intake_source_check
  check (intake_source = any (array['mail','paper','pdf','infomart','api','manual','email_auto']));

create unique index if not exists invoices_biz_key_auto_uk
  on public.invoices (biz_key)
  where biz_key is not null and intake_source = 'email_auto' and invoice_status <> 'cancelled';

alter table public.invoice_attachments add column if not exists ocr_done_at timestamptz;

alter table public.invoice_emails
  add column if not exists auto_invoice_at timestamptz,
  add column if not exists auto_invoice_note text;
