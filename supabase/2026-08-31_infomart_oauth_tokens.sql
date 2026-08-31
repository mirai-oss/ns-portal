-- 2026-08-31 担当D: インフォマート受発注API OAuth連携用トークン保存テーブル（D-9）
-- mf_oauth_tokens（マネーフォワード連携）と全く同じ設計（RLS有効・ポリシーなし＝service_roleのみアクセス可）。
-- infomart-oauth-callback Edge Functionが認可コード↔トークン交換後にここへupsertする。
create table if not exists infomart_oauth_tokens (
  id text primary key default 'default',
  access_token text not null,
  refresh_token text not null,
  scope text,
  token_type text not null default 'Bearer',
  expires_at timestamptz not null,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  label text
);
alter table infomart_oauth_tokens enable row level security;
-- ポリシーは意図的に作らない（service_roleのみアクセス可能。mf_oauth_tokensと同じ方針）
