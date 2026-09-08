-- 2026-09-08: 取引先の振込先口座「支払方法」に、クレジット払い・他行口座から振込を追加
-- （担当C・invoices.html）
-- ユーザー要望「支払い方法にクレジット払い、他行口座から振込を追加する」に対応。
-- credit_card=クレジット払い（direct_debit/cashと同じく銀行口座情報は不要・CSV出力の対象外）、
-- other_bank_transfer=他行口座から振込（bank_transferと同じく銀行口座情報を持つが、
-- PayPay銀行のCSV一括振込の対象外＝別の銀行から手動で振込む想定。そのため銀行コード・
-- 支店コードの厳密な形式チェックはbank_transferのときだけ必須にしている＝invoices.html側）

alter table vendor_bank_accounts
  drop constraint if exists vendor_bank_accounts_payment_method_check;

alter table vendor_bank_accounts
  add constraint vendor_bank_accounts_payment_method_check
  check (payment_method in ('bank_transfer','direct_debit','cash','credit_card','other_bank_transfer'));

comment on column vendor_bank_accounts.payment_method is
  '支払方法。bank_transfer=銀行振込（PayPay銀行CSV出力の対象）、other_bank_transfer=他行口座から振込（銀行口座情報はあるがPayPay銀行CSVの対象外・手動で振込）、direct_debit=引き落とし、cash=現金払い、credit_card=クレジット払い（direct_debit/cash/credit_cardは銀行口座情報が不要・いずれもCSV出力の対象外。振込一覧で「済」にすると本部タスクの振込完了工程が完了扱いになる点はbank_transferと同じ）';
