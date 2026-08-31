-- 2026-08-31 担当B（nippo）B-16調査
-- 給与明細APIの生レスポンスに含まれる「控除内訳」「有給残数」を、専用カラムとしても
-- 取り出せるようにする（raw列にも既に入っているが、クエリしやすくするため）。
-- 参照: docs/実装指示書_ラウンド5_2026-08-31.md §2 B-16
alter table sf_payroll_sync
  add column if not exists deduction_total numeric,   -- deductionWage各項目のresultAmount合計
  add column if not exists deductions jsonb,           -- deductionWage配列そのまま（label/金額の内訳）
  add column if not exists net_pay numeric,             -- netPay（差引支給額。トップレベルのnetPayフィールド）
  add column if not exists paid_holiday_used_days numeric,      -- shiftTime.paidHolidayCount（今月の有給取得日数）
  add column if not exists remaining_paid_holiday_days numeric; -- shiftTime.remainingPaidHoliday（有給残日数）
comment on column sf_payroll_sync.remaining_paid_holiday_days is 'スマレジAPIのフィールドとしては存在するが、2026-08-31時点で調査した全員が0を返しており、スマレジ側で有給残数の計算が実際には運用されていない可能性が高い（B-16調査結果）。信頼できる値として扱う前に運用確認が必要';
