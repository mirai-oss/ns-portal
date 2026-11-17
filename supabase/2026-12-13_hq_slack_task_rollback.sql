-- 2026-12-13_hq_slack_task.sql の戻し（作ったタスクの行は消さない。ログの表だけ落とす）
drop function if exists public.hq_slack_step_ack(text, uuid);
drop function if exists public.hq_slack_step_complete(text, uuid);
drop function if exists public.hq_slack_reminder_release(uuid, uuid, text);
drop function if exists public.hq_slack_reminder_claim(uuid, uuid, text);
drop function if exists public.hq_slack_reminder_candidates();
drop function if exists public.hq_slack_task_create(text, text, text, uuid[], date, text, boolean, text, jsonb);
drop function if exists public.hq_slack_flag(text);
drop function if exists public.hq_slack_is_service();
drop table if exists public.hq_slack_reminder_log;
drop table if exists public.hq_slack_task_log;
delete from app_settings where key = 'hq_task_slack';
