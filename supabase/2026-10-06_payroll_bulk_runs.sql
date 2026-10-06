-- 担当C: 給与仕訳の全自動化 §6「チェックした人をまとめて登録」の実行ログ
-- 設計の正: docs/設計書_給与仕訳の全自動化_2026-10-06.md §6（一括登録の実行ログ＝誰が・いつ・何人・失敗）
--
-- 【事前報告様式（DB変更）】
-- 理由: 一括登録で「誰が・いつ・何人登録し、誰が失敗したか」を後から追えるようにしたい。
-- 現構造: payroll_journal_records は1人1月の登録記録（created_by・created_at は既にあるが、一括登録かどうか・
--         失敗した人は残らない）。
-- 変更（追加のみ）:
--   ① payroll_journal_records に batch_id(uuid)・registered_via(text, 'bulk'など) を追加（null許容）
--   ② 新規テーブル payroll_bulk_runs（1回の一括登録＝1行。対象人数・成功数・失敗者の内訳をjsonbで保存）。
--      RLSは他の給与仕訳テーブルと同じ invoice_can_access()
-- 既存データへの影響: なし（列追加(null許容)・新規テーブルのみ）。画面側は列・テーブルが無い間は従来どおり動く
--   （存在をその都度確認し、無ければ記録だけ省略）。
-- migration: 本ファイル(何度流しても壊れない)。 rollback: drop table payroll_bulk_runs; alter table payroll_journal_records drop column batch_id, drop column registered_via;

alter table public.payroll_journal_records add column if not exists batch_id uuid;
alter table public.payroll_journal_records add column if not exists registered_via text;

create table if not exists public.payroll_bulk_runs (
  id uuid primary key default gen_random_uuid(),
  year_month text not null,
  executed_by uuid references public.users(id),
  executed_at timestamptz not null default now(),
  total_count int not null,
  success_count int not null default 0,
  failed jsonb not null default '[]'::jsonb,   -- [{user_id,name,error}]
  user_ids jsonb not null default '[]'::jsonb  -- 対象にした全員のuser_id
);
alter table public.payroll_bulk_runs enable row level security;
drop policy if exists pbr_all on public.payroll_bulk_runs;
create policy pbr_all on public.payroll_bulk_runs for all
  using (invoice_can_access()) with check (invoice_can_access());
