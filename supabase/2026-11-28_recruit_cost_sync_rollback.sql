-- 2026-11-28_recruit_cost_sync.sql の戻し（反映済みの金額は変えない）
begin;
select cron.unschedule('recruit-cost-sync');
drop function if exists public.recruit_cost_sync_trigger();
drop function if exists public.recruit_cost_replace(date, jsonb);
delete from app_settings where key = 'recruit_cost_sheet';
delete from app_secrets where key = 'recruit_cost_sheet_id';
commit;
