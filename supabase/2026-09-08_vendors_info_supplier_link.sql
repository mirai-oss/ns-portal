-- 2026-09-08: 取引先マスタ（public.vendors・ns-portal/invoices.html・担当C）と
-- 社内情報管理システムの取引先（info.suppliers・ns-info-system・担当F）を「軽く連携」する。
-- ユーザー要望「取引先マスタは社内情報管理システムの取引先と連動されてるかな？されてなければ
-- 連動させて欲しい」への回答として、まず現状を調査した結果:
--   - 両者は同じSupabaseプロジェクト（uuvsxzhpxtghojoubjcc）内の別スキーマに存在するが、
--     現在は一切連携していない
--   - 持っている項目がそもそも大きく異なる（info.suppliersは電話番号・担当者名・取引状況などの
--     一般連絡先台帳。public.vendorsは銀行口座・支払方法など請求書処理用の情報で、
--     info.suppliers側には銀行口座情報が無い）
-- ユーザーと相談の結果、「軽い連携」（取引先を編集するとき、情報管理システム側に同名の
-- 取引先があれば候補として表示し、手動で『この会社です』と紐付けられるようにする。自動での
-- 書き換え・同期はしない、あくまで参照だけの連携）を採用した。

alter table vendors
  add column if not exists info_supplier_id uuid references info.suppliers(id) on delete set null;

comment on column vendors.info_supplier_id is
  '社内情報管理システム（ns-info-system）のinfo.suppliers.idへの参照（任意・手動リンク）。
   ユーザーが「取引先の紐付け」画面で手動で選んで設定する。自動同期はしない
   （info.suppliersは電話番号・担当者名等の一般連絡先台帳、こちらは銀行口座・支払方法等の
   請求書処理用データのため、持っている項目が異なる）。編集画面での参照表示にのみ使う。';
