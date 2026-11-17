-- @アプリ へのメンションで本部タスクの下書きを作る（2026-11-17・社長依頼）
--   AI（Claude Haiku 5.5）は、文章から下書き（タスク名・工程・担当者・期限・詳細）を作るだけ。作成は、メンションした本人が「作成する」を押したときだけ（DB の関数 hq_slack_task_create_steps が権限・内容を確かめる）。
--   設定 app_settings.hq_task_slack: ai_enabled（既定 false）・ai_daily_cap（1 日の上限・既定 200）・ai_model。
--   hq_slack_ai_log: 1 回の呼び出しの記録（イベントの二重処理を防ぐ・1 日の上限の数え上げ・トークン数）。本文は保存しない。
--   hq_slack_ai_draft: 下書き（メンションした人・場所・内容・状態）。本人以外は作成できない。
-- 戻し方: drop table hq_slack_ai_draft; drop table hq_slack_ai_log; app_settings の 3 つのキーを消す
update app_settings set value = value || '{"ai_enabled": false, "ai_daily_cap": 200, "ai_model": "claude-haiku-5-5"}'::jsonb where key = 'hq_task_slack' and not (value ? 'ai_enabled');
create table if not exists public.hq_slack_ai_log (
  event_id   text primary key,                 -- Slack のイベント ID（再送されても 1 回だけ処理）
  user_id    uuid,
  status     text not null,                    -- ok / rejected / failed / over_cap
  in_tokens  integer, out_tokens integer,
  created_at timestamptz not null default now()
);
create table if not exists public.hq_slack_ai_draft (
  id                 uuid primary key default gen_random_uuid(),
  requester_id       uuid not null,
  channel_id         text not null,
  thread_ts          text not null,
  draft              jsonb not null,
  status             text not null default 'open' check (status in ('open', 'created', 'canceled')),
  task_id            uuid,
  card_notification_id uuid,
  created_at         timestamptz not null default now()
);
alter table public.hq_slack_ai_log enable row level security;
alter table public.hq_slack_ai_draft enable row level security;
revoke all on public.hq_slack_ai_log from public, anon, authenticated;
revoke all on public.hq_slack_ai_draft from public, anon, authenticated;
