-- 2026-08-29 担当B（nippo）続き
-- ユーザー確認: regularWage（基本給のみ）だけでは固定残業代等が漏れる（青山純さんの例で確認）。
-- 給与明細の「課税対象額（切上げ）」を正の人件費として使いたい、交通費（通勤手当）も自動取得したい、との要望。
-- 生レスポンス(raw)で構造確認済み: totalTaxable=課税対象額、allowanceWage.transportation=通勤手当、
-- allowanceWage.fixedOvertimeWage=固定残業代（参考値として残す）
alter table sf_payroll_sync
  add column if not exists taxable_amount numeric,   -- totalTaxable（切上げ）。人件費として使う主要な値
  add column if not exists fixed_overtime_wage numeric, -- allowanceWage.fixedOvertimeWage（参考値）
  add column if not exists commute_allowance numeric;   -- allowanceWage.transportation（通勤手当・自動取得分。手入力の上乗せはsf_payroll_allocations(kind='commute')側で行う）
comment on column sf_payroll_sync.taxable_amount is '課税対象額（切上げ）。2026-08-29ユーザー指示によりこちらを人件費計算の主要な値として使う（regular_wageだけだと固定残業代等が漏れるため）';
