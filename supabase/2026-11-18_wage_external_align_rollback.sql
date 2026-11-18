drop trigger if exists wage_external_link_after_write on public.employee_wage_settings;
drop function if exists public.wage_external_link_after_write();
drop function if exists public.hr_wage_external_align_deleted(uuid, text, uuid);
-- hr_wage_external_request は 2026-11-18_wage_external_request.sql の定義（new_row だけ）に戻す場合は、そのファイルの create or replace を再実行する
