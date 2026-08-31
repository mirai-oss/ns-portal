-- 給与振込先に「現金手渡し」を選べるように（2026-09-01）
-- ユーザー要望: 振込先の登録するところに現金手渡しと選択できるようにしたい。
-- 現金手渡しの場合は銀行口座の情報が無くてもよいので、必須制約を緩める。
alter table payroll_bank_accounts add column if not exists payment_method text not null default 'bank_transfer'
  check (payment_method in ('bank_transfer','cash'));
alter table payroll_bank_accounts alter column bank_code drop not null;
alter table payroll_bank_accounts alter column branch_code drop not null;
alter table payroll_bank_accounts alter column account_number drop not null;
alter table payroll_bank_accounts alter column account_holder_kana drop not null;
