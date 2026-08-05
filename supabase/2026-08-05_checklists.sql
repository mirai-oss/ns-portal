-- ============================================================
-- 現場ルーティンチェックシート（フェーズ3b）
-- 画面=日報システム（現場アプリ）／データ=ハブ
-- テンプレ編集: マスター・社長・本部＋店舗管理権限 ／ チェック: ログインユーザー全員
-- 冪等。
-- ============================================================

-- テンプレ管理権限（マスター/社長/本部）
create or replace function checklist_can_manage() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select (u.is_master or u.role in ('CEO','HQ'))
     from users u where u.id = auth.uid() and u.is_active),
    false
  );
$$;

-- チェックシートのテンプレート（例: オープン準備）
create table if not exists checklist_templates (
  id uuid primary key default gen_random_uuid(),
  title text not null,                          -- 例: オープン準備
  period text not null default 'open',          -- open / prep / close / other（表示グループ）
  store_id uuid references stores(id) on delete cascade,  -- null = 全店舗共通
  sort_order int not null default 100,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- テンプレートの項目（例: 電気をつける）
create table if not exists checklist_items (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references checklist_templates(id) on delete cascade,
  label text not null,
  photo_required boolean not null default false,  -- 写真報告が必要な項目
  sort_order int not null default 100,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- 実施記録（店舗×日付×項目で1件）
create table if not exists checklist_checks (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references checklist_items(id) on delete cascade,
  store_id uuid not null references stores(id) on delete cascade,
  work_date date not null,
  checked_by uuid references users(id) on delete set null,
  checked_at timestamptz not null default now(),
  photo_url text,
  unique (item_id, store_id, work_date)
);
create index if not exists checklist_checks_day_idx on checklist_checks (store_id, work_date);

alter table checklist_templates enable row level security;
alter table checklist_items enable row level security;
alter table checklist_checks enable row level security;

drop policy if exists ckt_read on checklist_templates;
create policy ckt_read on checklist_templates for select using (auth.uid() is not null);
drop policy if exists ckt_write on checklist_templates;
create policy ckt_write on checklist_templates for all
  using (checklist_can_manage()) with check (checklist_can_manage());

drop policy if exists cki_read on checklist_items;
create policy cki_read on checklist_items for select using (auth.uid() is not null);
drop policy if exists cki_write on checklist_items;
create policy cki_write on checklist_items for all
  using (checklist_can_manage()) with check (checklist_can_manage());

drop policy if exists ckc_read on checklist_checks;
create policy ckc_read on checklist_checks for select using (auth.uid() is not null);
drop policy if exists ckc_insert on checklist_checks;
create policy ckc_insert on checklist_checks for insert
  with check (auth.uid() is not null and checked_by = auth.uid());
-- 取消（削除）: 自分が付けたチェック、または管理者
drop policy if exists ckc_delete on checklist_checks;
create policy ckc_delete on checklist_checks for delete
  using (checked_by = auth.uid() or checklist_can_manage());
