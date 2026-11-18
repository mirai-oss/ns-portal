-- 本部タスクの親投稿（Slack のチャンネル）を、管理システム（画面）の操作にも 1 分以内に追従させる定期実行（2026-11-18）。
--   呼び先: EF hq-task-reminders（op=refresh_parents, only_changed=true）。表示が変わったタスクの親投稿だけを書き換える（変わっていなければ Slack へは何もしない）。
--   社内の Slack の既存投稿を直すだけ。応募者・外部への送信なし。dm_enabled 等のスイッチには触れない。
-- 戻し方: select cron.unschedule('hq-parents-refresh'); drop function public.hq_parents_refresh_trigger();
create or replace function public.hq_parents_refresh_trigger() returns void language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/hq-task-reminders';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_req bigint;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'hq_parents_refresh_trigger: app_secrets.notify_slack_secret が未設定'; return; end if;
  select net.http_post(url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'refresh_parents', 'only_changed', true, 'max', 40), timeout_milliseconds := 55000) into v_req;
end $$;
revoke all on function public.hq_parents_refresh_trigger() from public, anon, authenticated;
select cron.schedule('hq-parents-refresh', '* * * * *', 'select public.hq_parents_refresh_trigger()');
-- 確認（1 行・schedule が * * * * *、active が true なら OK）
select jobname, schedule, active from cron.job where jobname = 'hq-parents-refresh';
