-- =====================================================================
-- 所属の双方向同期ジョブ(smaregi-affiliation-sync)用: 同期ログ・店舗追加タスクの冪等表（担当D・2026-10-17）
-- 設計: docs/設計メモ_スマレジ複数契約対応_2026-10-15.md §11-2 / §11-5
-- 【影響】新規テーブル2つの追加のみ。既存テーブルは変更しない。
-- 【個人情報】ログは user_id と店舗名・事業所IDのみ（氏名は持たない）。anon/authenticatedからは読めない（service_role・SQL実行者のみ）。
-- 【rollback】 drop table if exists public.smaregi_store_task_links, public.staff_store_sync_log;
-- 実行場所: Supabase SQL Editor（何度実行しても壊れません）
-- =====================================================================
create table if not exists public.staff_store_sync_log (
  id bigserial primary key,
  run_id uuid not null,
  at timestamptz not null default now(),
  mode text not null check (mode in ('report','apply')),     -- report=試行(書き込みなし) / apply=実際に反映
  contract_id text not null,
  user_id uuid references public.users(id) on delete set null,
  kind text not null check (kind in ('push','import','conflict_overwrite','skip','new_store','unmapped_store','auto_mapped','task_created','task_done','error')),
  detail jsonb not null default '{}'::jsonb
);
create index if not exists staff_store_sync_log_at_idx on public.staff_store_sync_log (at desc);
create index if not exists staff_store_sync_log_user_idx on public.staff_store_sync_log (user_id, at desc);

-- 管理システムに店舗を追加したがスマレジに事業所が無いとき、本部タスクを1店舗×契約につき1回だけ作るための対応表
create table if not exists public.smaregi_store_task_links (
  store_id uuid not null references public.stores(id) on delete cascade,
  contract_id text not null,
  task_id uuid references public.hq_tasks(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (store_id, contract_id)
);

alter table public.staff_store_sync_log enable row level security;
alter table public.smaregi_store_task_links enable row level security;
revoke all on public.staff_store_sync_log, public.smaregi_store_task_links from anon, authenticated;
