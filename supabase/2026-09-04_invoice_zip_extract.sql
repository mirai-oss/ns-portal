-- ZIP添付の展開対応（2026-09-04・指示書§5-8「ZIP対応は新規実装してください」）
-- 目的はZIPの中にある実際の請求書PDFをinvoiceの証憑として正しく紐付けること。
-- zip_extracted_at: 元のZIP添付行がいつ展開されたか（二重展開防止・UI側の「展開済み」表示用）
-- extracted_from_zip_id: 展開して作られた個別ファイル添付行が、どのZIP添付から来たか（監査用）
alter table invoice_attachments add column if not exists zip_extracted_at timestamptz;
alter table invoice_attachments add column if not exists extracted_from_zip_id uuid references invoice_attachments(id);
create index if not exists invoice_attachments_zip_source_idx on invoice_attachments (extracted_from_zip_id);
