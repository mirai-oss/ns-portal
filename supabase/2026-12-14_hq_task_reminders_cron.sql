-- 本部タスクの Slack DM 通知の定期実行（2026-11-17）。呼び先: EF hq-task-reminders。スイッチ hq_task_slack.dm_enabled が false の間は、EF が何も送らない。
--   毎日 9:00 と 15:15（日本時間）= UTC 0:00 と 6:15。15 時以降の実行では、期限当日・超過の「対応中」を押していない工程に追い通知（_pm）が出る。
-- 戻し方: select cron.unschedule('hq-task-reminders-am'); select cron.unschedule('hq-task-reminders-pm'); drop function public.hq_task_reminders_trigger();
create or replace function public.hq_task_reminders_trigger() returns void language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/hq-task-reminders';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_req bigint;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'hq_task_reminders_trigger: app_secrets.notify_slack_secret が未設定'; return; end if;
  select net.http_post(url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('trigger', 'pg_cron'), timeout_milliseconds := 120000) into v_req;
end $$;
revoke all on function public.hq_task_reminders_trigger() from public, anon, authenticated;
select cron.schedule('hq-task-reminders-am', '0 0 * * *', 'select public.hq_task_reminders_trigger()');
select cron.schedule('hq-task-reminders-pm', '15 6 * * *', 'select public.hq_task_reminders_trigger()');
