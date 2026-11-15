-- 2026-12-08_payroll_transfer_task_autocomplete.sql の戻し（名簿が全員チェック済みでも、人が工程を完了にする作りに戻る）。
drop trigger if exists payroll_transfer_task_autocomplete on public.hq_step_checklist_items;
drop function if exists public.payroll_transfer_task_autocomplete();
