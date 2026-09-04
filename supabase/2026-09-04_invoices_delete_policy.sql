-- 請求書の削除を許可（テストデータの削除用・2026-09-04・会計・請求書処理の全面刷新）
-- ユーザー要望「テストで入力してる請求書もあるから、こちらは削除できるようにしてほしい」に対応。
-- 既存のinsert/updateと同じinvoice_can_access()ポリシー。会計登録済み（mf_journal_id有）の
-- 削除はフロント側で強い確認を出す設計とし、DB側は他のinvoices操作と同じ権限のまま統一する。
-- 実際にMoneyForward側へ登録済みの仕訳は、この削除では取り消されない（ローカルの記録が
-- 消えるだけ）ため、フロント側の確認文言でその旨を必ず伝える
drop policy if exists inv_invoices_delete on invoices;
create policy inv_invoices_delete on invoices for delete using (invoice_can_access());
