-- 段階5（2026-11-28_bank_ledger_stage5.sql）の取り消し。状態: 下書き（未適用）
-- 次のどれかがあると、何も消さずに止まる:
--   ・紐付けの履歴（bank_assignment_history）に 1 件でもある
--   ・複数店舗共有（multi）の口座、または口座名義の確認の記録（corporation_bank_account_id）と結んだ口座がある
--   ・運営法人の履歴（store_corporation_periods）に、段階5の初期データ以外（人が足した期間・終了日を入れた期間）がある
do $$
declare n bigint := 0; m bigint := 0; p bigint := 0;
begin
  if to_regclass('public.bank_assignment_history') is not null then select count(*) into n from public.bank_assignment_history; end if;
  if n > 0 then raise exception '紐付けの履歴に % 件のデータが入っています。取り消しを中止しました', n; end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'bank_accounts' and column_name = 'usage_mode') then
    execute $q$select count(*) from public.bank_accounts where usage_mode <> 'single' or corporation_bank_account_id is not null$q$ into m;
  end if;
  if m > 0 then raise exception '共有口座または名義確認と結んだ口座が % 件あります。取り消しを中止しました', m; end if;
  if to_regclass('public.store_corporation_periods') is not null then
    select count(*) into p from public.store_corporation_periods where not (valid_from = date '2000-01-01' and valid_to is null and note like '初期データ（段階5%');
  end if;
  if p > 0 then raise exception '運営法人の履歴に、人が足した期間が % 件あります。取り消しを中止しました', p; end if;
end $$;
drop function if exists public.bank_account_link_holder(uuid, uuid, text);
drop function if exists public.bank_assignment_revert(uuid, text);
drop function if exists public.bank_tx_assign_store(uuid[], uuid, text, boolean);
drop function if exists public.bank_account_assign_store(uuid, uuid, text);
drop function if exists public.bank_unassigned_list(uuid, integer);
drop function if exists public.bank_unassigned_summary();
drop function if exists public.store_corporation_change(uuid, uuid, date, text);
drop function if exists public.store_corporation_on(uuid, date);
drop table if exists public.bank_assignment_history;
drop table if exists public.store_corporation_periods;
drop function if exists public.store_corp_periods_guard();
drop function if exists public.bank_corp_ok(uuid);
drop function if exists public.bank_allowed_corp_ids();
drop function if exists public.bank_global_admin();
drop function if exists public.bank_user_corp_restricted();
alter table public.bank_accounts drop constraint if exists bank_accounts_multi_no_store;
alter table public.bank_accounts drop constraint if exists bank_accounts_usage_mode_check;
alter table public.bank_accounts drop column if exists corporation_bank_account_id;
alter table public.bank_accounts drop column if exists usage_mode;
