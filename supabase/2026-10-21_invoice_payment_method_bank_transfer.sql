-- 2026-10-21 担当C: 請求書の支払方法を 銀行振込／引き落とし／現金払い／クレジット払い の4つにする。
-- PayPay銀行CSV（bank_transfer）は給与の支払い専用（payroll_bank_accounts）になったため、請求書側（vendor_bank_accounts）の bank_transfer を
-- 新しい「銀行振込」（other_bank_transfer＝口座情報を登録して手動で振込）へ移す。これで、これまで bank_transfer だった取引先も引き落とし・銀行振込の自動照合の対象になる。
update public.vendor_bank_accounts set payment_method = 'other_bank_transfer', updated_at = now() where payment_method = 'bank_transfer';
alter table public.vendor_bank_accounts alter column payment_method set default 'other_bank_transfer';
