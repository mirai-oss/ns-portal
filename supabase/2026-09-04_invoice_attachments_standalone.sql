-- アップロード請求書の証憑をinvoice_attachmentsにも保存できるようにする（2026-09-04）
-- ユーザー報告「アップロード請求書から入力すると、会計が添付されたとしても、請求書一覧の
-- 処理を開くとプレビューで請求書が表示されない」に対応。
-- アップロード請求書（メールに紐付かない請求書）の証憑ファイルは、これまでマネーフォワード
-- 側のvoucher_filesとしてのみ送られ、Supabase側（invoice_attachments）には一切保存して
-- いなかったため、統合詳細モーダルの証憑プレビューに何も出せなかった。
-- email_idはメール起点の請求書にしか無いため、invoice_idでも紐付けられるよう列を追加し、
-- 「email_idかinvoice_idのどちらかは必須」という制約に変更する
alter table invoice_attachments alter column email_id drop not null;
alter table invoice_attachments add column if not exists invoice_id uuid references invoices(id);
alter table invoice_attachments drop constraint if exists invoice_attachments_email_or_invoice_chk;
alter table invoice_attachments add constraint invoice_attachments_email_or_invoice_chk
  check (email_id is not null or invoice_id is not null);
create index if not exists invoice_attachments_invoice_idx on invoice_attachments (invoice_id);
