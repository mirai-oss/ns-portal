-- 2026-08-29 担当B（nippo）続き
-- ユーザーから再訂正: 人件費として使うべきなのは「課税対象額」ではなく
-- 「支給額合計（切上げ）− 通勤手当」＝本来の固定給（基本給＋固定残業代等、交通費は含まない）。
-- 実データで検証済み: 青山純さん totalAllowance(293984) - transportation(13480) - 交通費allowance(504)
--   = 280,000円 = regularWage(220,000)+fixedOvertimeWage(60,000)と完全一致
alter table sf_payroll_sync
  add column if not exists total_allowance numeric,   -- totalAllowance（切上げ）＝支給額合計
  add column if not exists fixed_salary_amount numeric; -- total_allowance − 通勤手当関連。人件費計算で使う主要な値
comment on column sf_payroll_sync.fixed_salary_amount is '支給額合計（切上げ）から通勤手当を差し引いた金額＝本来の固定給。2026-08-29ユーザー指示によりこちらを人件費計算の主要な値として使う（taxable_amountは参考値として残すのみ）';
