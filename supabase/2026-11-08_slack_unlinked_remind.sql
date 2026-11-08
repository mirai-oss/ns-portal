-- 2026-11-08 Slack 未連携の従業員を毎朝 Slack のチャンネルにリマインド（ユーザー指示・チャンネル C0CFE1Y9HC7）
--   毎朝 09:30 の照合（slack-link-sync）の 15 分後に、EF slack-link op=remind が「管理システムに登録済みで Slack 未連携の人」を一覧にして送る（0 人なら送らない）
insert into public.slack_channels (channel_key, slack_channel_id, display_name, purpose, is_active)
values ('hq.slack_unlinked', 'C0CFE1Y9HC7', '#Slack未連携リマインド', 'Slack に登録・紐づけされていない従業員の毎朝のリマインド（2026-11-08）', true)
on conflict (channel_key) do update set slack_channel_id = excluded.slack_channel_id, display_name = excluded.display_name, purpose = excluded.purpose, is_active = true, updated_at = now();

create or replace function public.slack_unlinked_remind_trigger()
returns void
language plpgsql
security definer
set search_path to 'public', 'net', 'extensions'
as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/slack-link';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_req bigint;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'slack_unlinked_remind_trigger: notify_slack_secret 未設定'; return; end if;
  select net.http_post(
    url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'remind', 'trigger', 'pg_cron'),
    timeout_milliseconds := 60000
  ) into v_req;
end $$;
revoke all on function public.slack_unlinked_remind_trigger() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'slack-link-remind') then perform cron.unschedule('slack-link-remind'); end if;
  perform cron.schedule('slack-link-remind', '45 0 * * *', $cmd$select public.slack_unlinked_remind_trigger()$cmd$);   -- 09:45 JST（照合 09:30 の後）
end $$;
