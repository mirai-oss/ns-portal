-- マネーフォワード クラウド会計 API連携（OAuth2）
-- 目的: ①PLデータの自動取得（承認して反映、は既存のCSV取込フローに合流）②請求書の仕訳自動登録（人がボタンを押して確定）
-- 認可コードフロー: https://api.biz.moneyforward.com/authorize → https://api.biz.moneyforward.com/token
-- クライアントID/シークレットはコードに書かない。Edge Function環境変数のみ（MF_CLIENT_ID・MF_CLIENT_SECRET）
-- アクセストークン有効期限1時間・リフレッシュトークン有効期限540日（refresh_tokenも使うたびにローテートされるため毎回上書き保存する）

-- OAuthトークン保管（1事業所=1行のシングルトン運用。クライアント側からは一切読めない＝Edge Function/service_roleのみアクセス）
create table if not exists mf_oauth_tokens (
  id text primary key default 'default',
  office_id text, -- MFの事業所ID。初回tenant.read呼び出しで確定するまではnull
  access_token text not null,
  refresh_token text not null,
  scope text,
  token_type text not null default 'Bearer',
  expires_at timestamptz not null,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

alter table mf_oauth_tokens enable row level security;
-- policyを意図的に作らない＝anon/authenticatedからは一切見えない・触れない。service_roleのみRLSをバイパスしてアクセス可能

-- 連携操作の監査ログ（誰が・いつ・何を: PL取得プレビュー/反映・仕訳登録など）
create table if not exists mf_sync_logs (
  id uuid primary key default gen_random_uuid(),
  action text not null, -- 'oauth_connected' | 'oauth_refreshed' | 'pl_fetch' | 'pl_apply' | 'journal_create' | 'journal_create_failed'
  actor_type text not null default 'human' check (actor_type in ('human','ai','system')),
  actor_user_id uuid references users(id),
  detail jsonb,
  created_at timestamptz not null default now()
);
alter table mf_sync_logs enable row level security;

create or replace function mf_can_access() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select u.is_master or u.role in ('CEO','HQ') from users u where u.id = auth.uid() and u.is_active), false)
    or coalesce((select po.allowed from portal_user_overrides po where po.user_id = auth.uid() and po.system_key = 'moneyforward'), false);
$$;

create policy mf_sync_logs_read on mf_sync_logs for select
  using (mf_can_access());
-- insertはEdge Function（service_role）からのみ行うためINSERTポリシーは作らない
