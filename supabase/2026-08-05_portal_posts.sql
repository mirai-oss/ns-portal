-- ============================================================
-- ポータル掲示板（社内発信・お知らせ）
-- 読み: ログインユーザー全員 ／ 投稿・編集・削除: マスター・社長・本部
-- 冪等。
-- ============================================================

-- 投稿権限の判定（マスター or 社長 or 本部）
create or replace function portal_can_post() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select (u.is_master or u.role in ('CEO','HQ'))
     from users u where u.id = auth.uid() and u.is_active),
    false
  );
$$;

create table if not exists portal_posts (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text not null default '',
  url text,                             -- YouTube/Instagram/X などのリンク（YouTubeは埋め込み表示）
  pinned boolean not null default false,
  created_by uuid references users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists portal_posts_created_idx on portal_posts (pinned desc, created_at desc);

alter table portal_posts enable row level security;

drop policy if exists posts_read on portal_posts;
create policy posts_read on portal_posts
  for select using (auth.uid() is not null);
drop policy if exists posts_write on portal_posts;
create policy posts_write on portal_posts
  for all using (portal_can_post()) with check (portal_can_post());
