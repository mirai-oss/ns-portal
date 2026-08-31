-- =============================================================
-- AI開発コックピット（担当H新設レーン・2026-08-31）
-- 「誰が・どのPCで・どのリポジトリ/ブランチを・どのタスクで・どこまで」を
-- ポータルの1画面（マスター限定）で見るためのテーブル群。接頭辞 ck_ はH専任。
-- 実行方法: このファイル全体をSupabase SQL Editorに貼り付けてRun（冪等・何度実行しても安全）
-- 参照: docs/実装指示書_AI開発コックピット_担当別_2026-08-31.md / docs/調査レポート_AI開発コックピット_2026-08-31.md
-- =============================================================

-- 端末（Mac mini / MacBook / 将来のOffice-PC等）
create table if not exists ck_devices (
  id uuid primary key default gen_random_uuid(),
  device_key text unique not null,          -- 'mac-mini' / 'macbook' など機械用の固定キー
  device_name text not null default '',     -- 画面表示名
  hostname text not null default '',
  os text not null default '',
  status text not null default 'offline' check (status in ('online','offline')),
  last_seen_at timestamptz,
  created_at timestamptz not null default now()
);

-- 開発タスク（本部タスクhq_tasksとは別物。開発専用）
create table if not exists ck_tasks (
  id uuid primary key default gen_random_uuid(),
  task_no bigint generated always as identity unique, -- 画面では TK-<番号> と表示
  title text not null,
  description text not null default '',
  priority text not null default 'mid' check (priority in ('highest','high','mid','low')),
  project text not null default '',         -- 例: ns-portal / tori-dashboard / nippo / 横断
  category text not null default '',        -- 例: 実装 / 設計ゲート / ユーザー作業 / 調査
  assignee_type text not null default 'ai' check (assignee_type in ('ai','human')),
  assignee_name text not null default '',   -- 担当A〜H / 司令塔 / 中山 / Mirai
  target_device_id uuid references ck_devices(id),
  target_session_id uuid,
  repository text not null default '',
  branch text not null default '',
  instruction_id uuid,                      -- ck_instructions.id（相互参照のため外部キーは張らない）
  status text not null default 'backlog' check (status in
    ('backlog','ready','in_progress','review','waiting_human','blocked','done','cancelled')),
  progress_percent int not null default 0 check (progress_percent between 0 and 100),
  blocker text not null default '',
  due_at timestamptz,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);
create index if not exists ck_tasks_status_idx on ck_tasks (status, updated_at desc);

-- 稼働セッション（Claude Code / 人 / 定期処理）。正本はローカルPCではなくこのテーブル
create table if not exists ck_sessions (
  id uuid primary key default gen_random_uuid(),
  session_key text unique not null,         -- '<device_key>:<担当名 or リポジトリ名>'
  device_id uuid references ck_devices(id),
  agent_type text not null default 'claude_code' check (agent_type in ('claude_code','human','scheduled','other')),
  agent_name text not null default '',      -- 担当A〜H / 司令塔 / 中山
  repository text not null default '',
  branch text not null default '',
  current_task_id uuid references ck_tasks(id),
  status text not null default 'running' check (status in
    ('running','waiting','blocked','idle','stopped','stale','disconnected')),
  progress_percent int not null default 0 check (progress_percent between 0 and 100),
  current_file text not null default '',
  blocker text not null default '',
  git_head text not null default '',
  changed_files_count int not null default 0,
  changed_files jsonb not null default '[]'::jsonb,
  started_at timestamptz not null default now(),
  last_heartbeat_at timestamptz not null default now()
);
create index if not exists ck_sessions_hb_idx on ck_sessions (last_heartbeat_at desc);

-- 指示書（画面のジェネレーターで作ったMarkdownを保存）
create table if not exists ck_instructions (
  id uuid primary key default gen_random_uuid(),
  task_id uuid references ck_tasks(id) on delete set null,
  title text not null,
  markdown text not null default '',
  target_agent text not null default '',
  target_device text not null default '',
  repository text not null default '',
  branch text not null default '',
  created_by uuid references users(id),
  created_at timestamptz not null default now()
);

-- 実行・変更履歴（hq_task_activityと同型の考え方）
create table if not exists ck_events (
  id uuid primary key default gen_random_uuid(),
  session_id uuid references ck_sessions(id) on delete set null,
  task_id uuid references ck_tasks(id) on delete set null,
  device_id uuid references ck_devices(id) on delete set null,
  event_type text not null default 'note',  -- task_start/progress/blocked/task_done/note/approval_request/approved/rejected/task_create/task_update
  message text not null default '',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists ck_events_created_idx on ck_events (created_at desc);
create index if not exists ck_events_task_idx on ck_events (task_id, created_at desc);

-- 承認キュー（破壊的操作は自動実行せずここで待つ）
create table if not exists ck_approvals (
  id uuid primary key default gen_random_uuid(),
  task_id uuid references ck_tasks(id) on delete set null,
  session_id uuid references ck_sessions(id) on delete set null,
  kind text not null default 'other',       -- db_destructive/migration_delete/prod_data/credential/billing/external_mail/prod_deploy/main_merge/other
  title text not null,
  detail text not null default '',
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references users(id)
);

-- コメント
create table if not exists ck_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references ck_tasks(id) on delete cascade,
  author_id uuid references users(id),
  author_name text not null default '',
  body text not null,
  created_at timestamptz not null default now()
);

-- =============================================================
-- RLS: 全テーブル・全操作をマスター限定（portal_is_master()を再利用）
-- anonキーはHTMLに公開されているため、この行が唯一の防御。絶対に外さない。
-- マシンからの書込（heartbeat）はEdge Function cockpit-ingest（service role）経由。
-- =============================================================
alter table ck_devices      enable row level security;
alter table ck_tasks        enable row level security;
alter table ck_sessions     enable row level security;
alter table ck_instructions enable row level security;
alter table ck_events       enable row level security;
alter table ck_approvals    enable row level security;
alter table ck_comments     enable row level security;

drop policy if exists ck_devices_master      on ck_devices;
drop policy if exists ck_tasks_master        on ck_tasks;
drop policy if exists ck_sessions_master     on ck_sessions;
drop policy if exists ck_instructions_master on ck_instructions;
drop policy if exists ck_events_master       on ck_events;
drop policy if exists ck_approvals_master    on ck_approvals;
drop policy if exists ck_comments_master     on ck_comments;

create policy ck_devices_master      on ck_devices      for all using (portal_is_master()) with check (portal_is_master());
create policy ck_tasks_master        on ck_tasks        for all using (portal_is_master()) with check (portal_is_master());
create policy ck_sessions_master     on ck_sessions     for all using (portal_is_master()) with check (portal_is_master());
create policy ck_instructions_master on ck_instructions for all using (portal_is_master()) with check (portal_is_master());
create policy ck_events_master       on ck_events       for all using (portal_is_master()) with check (portal_is_master());
create policy ck_approvals_master    on ck_approvals    for all using (portal_is_master()) with check (portal_is_master());
create policy ck_comments_master     on ck_comments     for all using (portal_is_master()) with check (portal_is_master());

-- 端末の初期登録
insert into ck_devices (device_key, device_name, os)
values ('mac-mini', 'Mac mini（本番）', 'macOS'), ('macbook', 'MacBook（開発）', 'macOS')
on conflict (device_key) do nothing;

-- heartbeat認証トークンの置き場（値は手順書に従いSQL Editorで直接投入。ここには書かない）
-- insert into app_secrets (key, value, updated_at) values ('cockpit_ingest_token', '<トークン>', now())
--   on conflict (key) do update set value = excluded.value, updated_at = now();
