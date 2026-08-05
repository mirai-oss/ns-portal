-- ============================================================
-- ポータル権限設定: 役割ごとの既定 ＋ 個人ごとの例外上書き
-- 対象: ハブ = 日報Supabaseプロジェクト (uuvsxzhpxtghojoubjcc)
-- 冪等。書き込みはマスター（users.is_master）のみ。
-- ============================================================

-- マスター判定（RLSから使う。security definerでusersを直接参照）
create or replace function portal_is_master() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select u.is_master from users u where u.id = auth.uid() and u.is_active),
    false
  );
$$;

-- 役割ごとの既定（role × system_key）
create table if not exists portal_permissions (
  role text not null,            -- CEO / HQ / TEAM / TENCHO / SHAIN / AL
  system_key text not null,      -- keiei / seisan / joho / nippo
  allowed boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (role, system_key)
);

-- 個人ごとの例外（あれば役割の既定より優先）
create table if not exists portal_user_overrides (
  user_id uuid not null references users(id) on delete cascade,
  system_key text not null,
  allowed boolean not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, system_key)
);

alter table portal_permissions enable row level security;
alter table portal_user_overrides enable row level security;

drop policy if exists pp_read on portal_permissions;
create policy pp_read on portal_permissions
  for select using (auth.uid() is not null);
drop policy if exists pp_write on portal_permissions;
create policy pp_write on portal_permissions
  for all using (portal_is_master()) with check (portal_is_master());

drop policy if exists po_read on portal_user_overrides;
create policy po_read on portal_user_overrides
  for select using (user_id = auth.uid() or portal_is_master());
drop policy if exists po_write on portal_user_overrides;
create policy po_write on portal_user_overrides
  for all using (portal_is_master()) with check (portal_is_master());

-- 初期値（要件定義書のアクセスマトリクス）。既に行があれば触らない。
insert into portal_permissions (role, system_key, allowed)
select v.r, v.s, v.a from (values
  ('CEO','keiei',true),   ('CEO','seisan',true),   ('CEO','joho',true),   ('CEO','nippo',true),
  ('HQ','keiei',true),    ('HQ','seisan',true),    ('HQ','joho',true),    ('HQ','nippo',true),
  ('TEAM','keiei',true),  ('TEAM','seisan',false), ('TEAM','joho',true),  ('TEAM','nippo',true),
  ('TENCHO','keiei',true),('TENCHO','seisan',false),('TENCHO','joho',false),('TENCHO','nippo',true),
  ('SHAIN','keiei',false),('SHAIN','seisan',false),('SHAIN','joho',false),('SHAIN','nippo',true),
  ('AL','keiei',false),   ('AL','seisan',false),   ('AL','joho',false),   ('AL','nippo',true)
) as v(r, s, a)
on conflict (role, system_key) do nothing;

-- 確認用:
-- select role, system_key, allowed from portal_permissions order by role, system_key;
