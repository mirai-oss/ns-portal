-- ロールバック: 固定残業代の設定（最小版）を外す。入れた値は消える（この列だけ。基本給などには触らない）
drop function if exists public.hr_set_fixed_ot(uuid, text, integer, integer);
drop table if exists fixed_ot_changes;
alter table employee_wage_settings drop constraint if exists employee_wage_settings_fixed_ot_chk;
alter table employee_wage_settings
  drop column if exists fixed_ot_state, drop column if exists fixed_ot_amount, drop column if exists fixed_ot_minutes,
  drop column if exists fixed_ot_set_by, drop column if exists fixed_ot_set_at;
