-- 仕入れ移動 公開フォームのSupabase直結化（2026-10-05）
-- 実行場所: Supabase SQL Editor / Management API（手動適用・冪等）
-- 背景: tori-dashboardの公開フォーム（?transferForm=<token>）がGAS経由だと、GASが毎回
-- 巨大なスプレッドシート全体を開くコストを払うため読み込みに数秒〜十数秒かかっていた。
-- 品目マスタ・申請キューをここに移し、ブラウザから直接読み書きできるようにする（詳細は
-- tori-dashboard側のHANDOFF.md・このファイルと対になるgas/Code.gsの変更を参照）。
-- PL本体（DB_PL）への反映・承認フローは引き続きtori-dashboard（GAS）側が担当する。

-- 品目マスタ（旧: DB_仕入れ移動品目マスタ）。ベーステーブルはservice_role（GAS）のみ読み書き可。
create table if not exists public.cost_transfer_items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  unit_price numeric not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.cost_transfer_items enable row level security;

-- 公開フォームが読む「公開してよい列だけ」のビュー（store_directory_vと同じ手法。
-- 2026-08-22_store_directory.sql参照）。有効な品目のみ・列は名前と単価だけに絞る。
create or replace view public.cost_transfer_items_v as
  select name, unit_price from public.cost_transfer_items where active = true order by name;
grant select on public.cost_transfer_items_v to anon;

-- 申請キュー（旧: DB_仕入れ移動申請）。こちらもservice_role（GAS・Edge Function）のみ読み書き可。
-- 公開フォームからのINSERTはcost-transfer-submit Edge Function（service_role）経由のみで、
-- ブラウザから直接このテーブルへはアクセスできない。
create table if not exists public.cost_transfer_requests (
  id uuid primary key default gen_random_uuid(),
  submitted_at timestamptz not null default now(),
  transfer_date date not null,
  from_store text not null,
  to_store text not null,
  items jsonb not null,
  total numeric not null,
  note text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  approver text,
  approved_at timestamptz,
  reject_reason text
);
alter table public.cost_transfer_requests enable row level security;

-- 公開リンクのトークン（旧: GASスクリプトプロパティ COST_TRANSFER_FORM_TOKEN）。
-- app_secretsの他のキーと同じ置き場所に統一する。プレースホルダの空文字で登録しておき、
-- 実際の値はtori-dashboard管理画面の「📋現場フォーム管理→公開リンク→🔄リンクを再発行する」で
-- 発行する（既存のリンク再発行＝即時無効化という挙動をそのまま引き継ぐ）。
insert into public.app_secrets (key, value, updated_at)
values ('cost_transfer_form_token', '', now())
on conflict (key) do nothing;
