-- 2026-10-14 取引先の「支店」（段階2.5）
-- 設計書: docs/設計書_取引先名の対応づけ_社内情報を正本に_2026-10-14.md §7
--
-- ユーザー情報: 取引先名（正式名）は同じで、その中に支店・営業所・事業部があり、
--               支店ごとに「担当者」と「発注する店舗」が違う。
-- 持ち方:  取引先(info.suppliers・正式名)  1 ──< 支店(info.supplier_branches)  1 ──< 発注する店舗(info.supplier_branch_stores)
--          請求書・明細での名前（vendor_aliases）は、どの支店の名前かを branch_id で持てる（任意）。
-- 冪等。データの書換えは無い（テーブル追加と列追加のみ）。権限は取引先と同じ（閲覧=ログイン済み／編集=has_edit_perm('supplier')）。

create table if not exists info.supplier_branches (
  id             uuid primary key default gen_random_uuid(),
  supplier_id    uuid not null references info.suppliers(id) on delete cascade,
  name           text not null,                       -- 支店名・営業所名・事業部名（例: 川崎営業所／リクエ事業）
  contact_name   text,                                -- この支店の担当者
  contact_mobile text,
  phone          text,
  email          text,
  memo           text,
  status         text not null default '取引中',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (supplier_id, name)
);
create index if not exists supplier_branches_supplier_idx on info.supplier_branches (supplier_id);

comment on table info.supplier_branches is
  '取引先の支店・営業所・事業部。取引先名（正式名）は info.suppliers に1件、支店ごとの担当者・発注する店舗はここ。';

create table if not exists info.supplier_branch_stores (
  branch_id  uuid not null references info.supplier_branches(id) on delete cascade,
  store_id   uuid not null references info.stores(id),
  created_at timestamptz not null default now(),
  primary key (branch_id, store_id)
);
create index if not exists supplier_branch_stores_store_idx on info.supplier_branch_stores (store_id);

comment on table info.supplier_branch_stores is '支店に発注する店舗（どの店舗がこの支店へ発注しているか）。';

-- 権限（取引先と同じ）
alter table info.supplier_branches enable row level security;
alter table info.supplier_branch_stores enable row level security;

drop policy if exists select_supplier_branches on info.supplier_branches;
create policy select_supplier_branches on info.supplier_branches for select using (auth.uid() is not null);
drop policy if exists write_supplier_branches on info.supplier_branches;
create policy write_supplier_branches on info.supplier_branches for all
  using (auth.uid() is not null and info.has_edit_perm('supplier'))
  with check (auth.uid() is not null and info.has_edit_perm('supplier'));

drop policy if exists select_supplier_branch_stores on info.supplier_branch_stores;
create policy select_supplier_branch_stores on info.supplier_branch_stores for select using (auth.uid() is not null);
drop policy if exists write_supplier_branch_stores on info.supplier_branch_stores;
create policy write_supplier_branch_stores on info.supplier_branch_stores for all
  using (auth.uid() is not null and info.has_edit_perm('supplier'))
  with check (auth.uid() is not null and info.has_edit_perm('supplier'));

grant select, insert, update, delete on info.supplier_branches to authenticated, service_role;
grant select, insert, update, delete on info.supplier_branch_stores to authenticated, service_role;

-- 請求書・明細での名前が、どの支店の名前か（任意）
alter table public.vendor_aliases
  add column if not exists branch_id uuid references info.supplier_branches(id) on delete set null;
comment on column public.vendor_aliases.branch_id is
  'この別名（請求書・明細での名前）がどの支店のものか。支店を特定できない別名は null。';
