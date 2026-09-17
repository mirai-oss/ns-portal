-- 2026-09-17: 売上入金（ar_receivables）の手動追加で証憑ファイルをアップロードできるように
-- するための新規テーブル。
--
-- 【なぜ必要か】
-- ユーザー報告「売上入金の手動アップロードの所（入金追加）がアップロードできない状態に
-- なってる。請求書みたいにアップロードできるようにしてほしい」。
-- 🧾請求書一覧の「＋ 請求書を追加」（openUploadModal）はファイルをドラッグ＆ドロップで
-- 取り込め、invoice_attachmentsに証憑として保存される。一方、💰売上入金タブの
-- 「＋ 入金を追加」（2026-09-15新設のopenReceivableUploadModal）は金額等のテキスト項目
-- しか無く、そもそもファイルを添付する仕組み自体が無かった。
--
-- 【現在の構造】invoice_attachments（invoice_id列を持つ・請求書専用）はあるが、
-- ar_receivables用の証憑テーブルは存在しない。汎用のattachments（owner_type/owner_id）
-- テーブルも存在するが、他システム（is_camera_capture列等から推測）向けのものとみられ、
-- RLS・運用規約が不明なため今回は使わず、invoice_attachmentsと同じ発想の専用テーブルを
-- 新設する方が安全と判断した。
--
-- 【今回の変更】ar_receivable_attachments（id・receivable_id・file_name・mime_type・
-- storage_path・file_hash・size_bytes・created_at）を新設。invoice_attachmentsと
-- ほぼ同じ列構成（zip_extracted_at等の請求書固有列は持たない）。ファイル本体は既存の
-- Storageバケット"invoice-files"を共用し、パスをreceivables/<receivable_id>/...で
-- 分離する（新規バケットは作らない）。
--
-- 【既存データへの影響】無し（新規テーブル追加のみ）
-- 【migration】このファイル自体（CREATE TABLE IF NOT EXISTSのみ・冪等）
-- 【rollback】drop table if exists ar_receivable_attachments;
-- 【既存機能への影響】無し。invoice_attachments・請求書側の証憑プレビュー等には一切触れていない。

create table if not exists ar_receivable_attachments (
  id uuid primary key default gen_random_uuid(),
  receivable_id uuid references ar_receivables(id) on delete cascade,
  file_name text not null,
  mime_type text,
  storage_path text not null,
  file_hash text,
  size_bytes bigint,
  created_at timestamptz not null default now()
);
comment on table ar_receivable_attachments is
  '売上入金（ar_receivables）の手動追加時にアップロードした証憑ファイル（精算明細PDF等）。
   invoice_attachmentsと同じ発想の専用テーブル。ファイル本体はStorageバケット
   "invoice-files"のreceivables/<receivable_id>/配下に保存する。';
create index if not exists ar_receivable_attachments_receivable_idx on ar_receivable_attachments(receivable_id);

-- 2026-09-17: RLSは意図的に有効化しない。invoice_attachments（RLS有効・SELECTのみ許可・
-- 書き込みはEdge Function/RPCのservice role経由）とは異なり、こちらはクライアントから
-- 直接INSERTする設計（このアプリは全社共通で新規テーブルの多くがそうであるように、
-- ar_receivables自体・ar_deposits等の同じ売上入金系テーブルもRLS無効で運用されている
-- ことを確認済み。それに揃える）。Storage側（invoice-filesバケット）はinvoice_can_access()
-- による既存ポリシーがパス（フォルダ名）を問わず適用されるため、receivables/配下への
-- アップロードも既存の仕組みでそのまま保護される。
