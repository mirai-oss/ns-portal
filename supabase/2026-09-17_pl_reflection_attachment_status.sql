-- 2026-09-17: 業務委託精算書への添付ファイル反映状況を可視化するためのスキーマ追加。
--
-- 【なぜ必要か】
-- ユーザー報告「精算書の添付には添付ファイルがない状態になってる。アップロードした請求書を
-- 精算書に反映させたら、その添付ファイルも精算書側の添付に反映させてほしい」。
-- 調査したところ、この機能自体は2026-09-10に既に実装済み（pl-fee-reflect/index.tsの
-- seisan_confirmアクションが、登録が成功した行ごとにinvoice_attachmentsを読み込み、
-- sd_apiUploadAttachment（精算書側のDrive連携API）へアップロードしている）。
-- ただし、①アップロードの成否（件数・失敗理由）はその場のレスポンス（results配列）にしか
-- 残らず、DBには一切保存していなかった②反映履歴カード（invoices.html側）にも表示していな
-- かった、ため、後からこの画面を開いても「添付できているのか・失敗しているのか」が
-- 一切わからない状態だった（今回のユーザー報告の直接の原因）。
-- また、同日発覚したTK-180（精算書側GAS Web AppがGoogleの認証ページを返している疑い）が
-- 事実なら、明細行の登録だけでなく添付アップロード（同じSEISAN_API_URL・同じseisanCall経由）
-- も同時に失敗している可能性が高い。今回の列追加は、その状況を今後この画面から直接
-- 確認できるようにするための土台。
--
-- 【現在の構造】invoice_pl_reflectionsは、明細行1件（請求書×勘定科目×補助科目×店舗）を
-- 表す行。sheet_synced_at/sheet_sync_error/pl_status等で「明細行自体」の同期状態は
-- 記録済みだが、「添付ファイル」の同期状態を記録する列が無かった。
--
-- 【今回の変更】
-- invoice_pl_reflections.attached_count（integer・既定0）：実際にアップロードできた
--   添付ファイル件数。
-- invoice_pl_reflections.attachment_error（text）：アップロード中に発生したエラー
--   （最初の1件のみ記録・複数ファイルある場合の全件は追わない簡易版）。
--
-- 【既存データへの影響】無し（新規列追加のみ・default値により既存行は全てattached_count=0・
-- attachment_error=nullになるが、これは「添付情報が無い」という意味であり、実際に添付済み
-- だった過去分の実態を誤って「失敗」と表示するものではない＝表示側は「未確認」として扱う）
-- 【migration】このファイル自体（ALTER TABLE ADD COLUMN IF NOT EXISTSのみ・冪等）
-- 【rollback】
--   alter table invoice_pl_reflections drop column if exists attached_count;
--   alter table invoice_pl_reflections drop column if exists attachment_error;
-- 【既存機能への影響】無し。既存のseisan_confirmの動作（アップロード自体）は変更せず、
-- 結果の記録・表示を追加するのみ。

alter table invoice_pl_reflections add column if not exists attached_count integer not null default 0;
alter table invoice_pl_reflections add column if not exists attachment_error text;
comment on column invoice_pl_reflections.attached_count is
  'この明細行の登録時に精算書側（Google Drive）へアップロードできた添付ファイルの件数。
   請求書に添付が無い場合は0（正常）。添付があるのに0の場合はattachment_errorを確認する。';
comment on column invoice_pl_reflections.attachment_error is
  '添付ファイルのアップロード中に発生した最初のエラー内容（複数ファイルある場合、2件目以降の
   個別エラーは追跡していない簡易版）。';
