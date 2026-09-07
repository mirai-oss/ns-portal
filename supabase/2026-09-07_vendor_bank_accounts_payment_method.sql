-- 2026-09-07: 取引先の振込先口座に「支払方法」を追加（担当C・invoices.html）
-- ユーザー要望「請求書の振込待ちのところで、引落とし・現金払いを選択できるようにしてほしい。
-- 引き落としと現金払いの場合は、振り込み口座登録してタスクと同じく振り込み準備中になるように」
-- 従来はvendor_bank_accountsが「銀行振込」しか想定しておらず、銀行コード・支店コード等の
-- 入力が事実上必須になっていた（PayPay銀行CSV出力のバリデーションのため）。
-- payroll_bank_accounts（給与の振込先口座）に既にある payment_method カラム
-- （'bank_transfer'|'cash'）と同じ考え方を、取引先の振込先口座にも導入する。
-- 今回はさらに「引き落とし（direct_debit）」も選べるようにする。

alter table vendor_bank_accounts
  add column if not exists payment_method text not null default 'bank_transfer';

alter table vendor_bank_accounts
  drop constraint if exists vendor_bank_accounts_payment_method_check;

alter table vendor_bank_accounts
  add constraint vendor_bank_accounts_payment_method_check
  check (payment_method in ('bank_transfer','direct_debit','cash'));

comment on column vendor_bank_accounts.payment_method is
  '支払方法。bank_transfer=銀行振込（従来どおりPayPay銀行CSV出力の対象）、direct_debit=引き落とし、cash=現金払い（どちらも銀行口座情報は不要・CSV出力の対象外。振込一覧で「済」にすると本部タスクの振込完了工程が完了扱いになる点は銀行振込と同じ）';
