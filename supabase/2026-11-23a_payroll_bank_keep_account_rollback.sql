-- 2026-11-23a_payroll_bank_keep_account.sql の戻し（引き金と関数を外す。控えの表は、行が無いときだけ消す）
drop trigger if exists payroll_bank_keep_account on public.payroll_bank_accounts;
drop function if exists public.payroll_bank_account_delete(uuid, text);
drop function if exists public.payroll_bank_keep_account();
do $$ begin
  if to_regclass('public.payroll_bank_account_archive') is not null and not exists (select 1 from public.payroll_bank_account_archive) then drop table public.payroll_bank_account_archive; end if;
end $$;
