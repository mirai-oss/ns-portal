-- =============================================================
-- 2026-11-08 Slack 登録 → 紐づけ → 本人へ通知 を「すぐ」に（ユーザー指示「登録したらすぐ連携完了させて Slack に通知して」）
--   背景: Slack の team_join イベントが届いた記録が無い（受け口は模擬イベントで正常）。Slack 側の設定に頼らず、照合（slack-link op=sync）を 10 分おきにし、
--         新しく紐づいた人には照合側からも本人 DM（＋hq.dev_system に記録）を送る。イベントが届けばその瞬間に（slack-events）。
--   受け取ったイベントは slack_event_log に全部残す（届いているか・なぜ紐づかなかったかを後から見るため）
-- =============================================================
create table if not exists public.slack_event_log (
  id          uuid primary key default gen_random_uuid(),
  event_type  text not null,
  slack_user_id text,
  email_masked text,
  result      text,          -- linked / already / no_match / no_email / user_already_linked / bot_or_deleted / error
  user_id     uuid,
  raw         jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists slack_event_log_created_idx on public.slack_event_log (created_at desc);
alter table public.slack_event_log enable row level security;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'slack-link-sync') then perform cron.unschedule('slack-link-sync'); end if;
  perform cron.schedule('slack-link-sync', '*/10 * * * *', $cmd$select public.slack_link_sync_trigger()$cmd$);   -- 10 分おき（旧: 毎朝 09:30）
end $$;
