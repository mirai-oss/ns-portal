-- 2026-12-06_payroll_transfer_task_check.sql の戻し。
-- 注意: 表を消すと、「照合がどのチェックを入れたか」の記録が失われる。先に控えを取ること。入れたチェックそのものは、消えない。
drop function if exists public.payroll_transfer_task_check(uuid);
drop table if exists public.payroll_transfer_task_checks;
