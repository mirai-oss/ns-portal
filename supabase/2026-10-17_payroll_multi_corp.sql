-- 給与仕訳のMF事業者（法人）切替（黒霧屋 新横浜の運営変更 2026-11-01・指示書§5-2）
-- ①店舗×MF事業者の給与の補助科目名（LiveGateの黒霧屋 新横浜 → 「新横浜/黒霧屋」。LiveGateの書き方=地域/店名）
alter table public.store_tenant_departments add column if not exists payroll_sub_name text;
update public.store_tenant_departments set payroll_sub_name = '新横浜/黒霧屋', updated_at = now()
 where tenant_id = 'livegate' and store_id = (select id from public.stores where name = '黒霧屋 新横浜');

-- ②給与仕訳の登録記録を「人×月×MF事業者」で1件にする（両社で働く人は契約ごとに仕訳2本・Q2=a。従来は人×月で1件だった）
update public.payroll_journal_records set tenant_id = 'default' where tenant_id is null;
alter table public.payroll_journal_records alter column tenant_id set default 'default';
alter table public.payroll_journal_records alter column tenant_id set not null;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'payroll_journal_records_user_month_tenant_key') then
    alter table public.payroll_journal_records add constraint payroll_journal_records_user_month_tenant_key unique (user_id, year_month, tenant_id);
  end if;
  alter table public.payroll_journal_records drop constraint if exists payroll_journal_records_user_id_year_month_key;
end $$;
