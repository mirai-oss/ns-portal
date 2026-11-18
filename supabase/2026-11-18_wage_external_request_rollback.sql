drop trigger if exists wage_external_link_before_insert on public.employee_wage_settings;
drop function if exists public.wage_external_link_before_insert();
drop function if exists public.hr_wage_external_request(uuid, text, uuid);
