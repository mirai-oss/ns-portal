-- 2026-11-08 Slack 招待の送り方に「メール」を追加（LINE 未連携の人向け。Resend で送る）。slack_invite_log.channel に 'email' を許す
alter table public.slack_invite_log drop constraint if exists slack_invite_log_channel_check;
alter table public.slack_invite_log add constraint slack_invite_log_channel_check check (channel in ('line', 'email', 'copy'));
