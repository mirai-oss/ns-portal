-- 2026-12-05_payroll_transfer_paid_and_evidence_fix.sql の戻し。
-- 注意: 表を消すと、「照合がどの印を入れたか」「どの証憑を除外したか」の記録が失われる。先に控えを取ること。
--       照合が入れた印（payroll_journal_records.paid_at）を外したいときは、消す前に、行ごとに payroll_transfer_paid_unmark を使う。
drop function if exists public.payroll_transfer_evidence_corrections_list(text, uuid);
drop function if exists public.payroll_transfer_evidence_correct(uuid, text, text);
drop function if exists public.payroll_transfer_paid_unmark(uuid, text);
drop function if exists public.payroll_transfer_paid_backfill(uuid);
drop table if exists public.payroll_transfer_evidence_corrections;
drop table if exists public.payroll_transfer_paid_marks;
