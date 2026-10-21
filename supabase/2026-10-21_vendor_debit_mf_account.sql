-- 2026-10-21 担当C: 支払方法=引き落とし の取引先に、引き落とし元の口座（MFの預金口座）を選べるようにする。
-- 目的: 「期日を過ぎても残っています」が出たとき、どの口座のMF入力（銀行連携の仕訳）が止まっているかを判断するため。
-- MFの口座は 勘定科目（普通預金など）＋補助科目（口座名）で表される。どのMF事業者（トーホー/N-Style/LiveGate/SK）の口座かも持つ。
alter table public.vendor_bank_accounts
  add column if not exists mf_debit_tenant text,
  add column if not exists mf_debit_account text,
  add column if not exists mf_debit_sub_account text;
comment on column public.vendor_bank_accounts.mf_debit_tenant is '引き落とし元口座のMF事業者（default=トーホー/nstyle/livegate/sk）';
comment on column public.vendor_bank_accounts.mf_debit_account is '引き落とし元口座のMF勘定科目（普通預金など）';
comment on column public.vendor_bank_accounts.mf_debit_sub_account is '引き落とし元口座のMF補助科目（口座名）';
