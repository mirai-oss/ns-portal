-- 2026-12-03_monthly_wage_sync_hold.sql の戻し。
-- 止めを外すだけなら 1 行目だけでよい（トリガーは残るが、設定が false のあいだは何もしない）。
update app_settings set value = value || '{"monthly_wage_sync_hold": false}'::jsonb where key = 'employee_change';
-- 全部を元に戻すとき:
drop trigger if exists monthly_wage_sync_hold_guard on public.employee_wage_settings;
drop function if exists public.monthly_wage_sync_hold_guard();
update app_settings set value = value - 'monthly_wage_sync_hold' - 'monthly_wage_sync_hold_exempt' where key = 'employee_change';
