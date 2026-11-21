-- 2026-11-21 担当B（社長依頼）— 管理システムで完了にした本部タスクの Slack の DM が「今日が期限です」のまま残る件
--  困りごと: タスクを管理システムで完了にしても、Slack の個人 DM（期限のリマインド・担当になった通知）は、ボタン付きのまま残る
--  やること: 10 分おきに EF hq-task-reminders（op=refresh_done）を呼び、完了・削除になった工程の DM を「✅ 完了済み」に書き換える（新しい通知は出さない・テーブルは触らない）
--  あわせて、直近 7 日で残っている分は、最初の実行でまとめて書き換わる
-- 【止め方・戻し方】select cron.unschedule('hq-task-done-sweep'); drop function public.hq_task_done_sweep_trigger();
begin;

create or replace function public.hq_task_done_sweep_trigger() returns void language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/hq-task-reminders';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_req bigint;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'hq_task_done_sweep_trigger: app_secrets.notify_slack_secret が未設定'; return; end if;
  select net.http_post(url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('trigger', 'pg_cron', 'op', 'refresh_done'), timeout_milliseconds := 120000) into v_req;
end $$;
revoke all on function public.hq_task_done_sweep_trigger() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'hq-task-done-sweep') then perform cron.unschedule('hq-task-done-sweep'); end if;
  perform cron.schedule('hq-task-done-sweep', '*/10 * * * *', $cmd$select public.hq_task_done_sweep_trigger()$cmd$);
end $$;

commit;
