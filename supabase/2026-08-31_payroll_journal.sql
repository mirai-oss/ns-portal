-- 給与明細 → MF仕訳（C-7③・2026-08-31）
-- 設計書_会計自動化_給与明細とインフォマート支払_2026-08-31.md §1・§5(Q2)の確定仕様どおり。
--
-- sf_payroll_sync（担当B・nippoの所有）は「読み取りは他システムも可」と明記されているため、
-- 給与額の読み取り元としてそのまま使う（列追加・書き込みはしない＝他担当のテーブルには触れない）。
-- 仕訳登録の進捗・紐付け情報は、担当C（会計）側の新規テーブルに持つ。

-- 従業員ごとに「どの仕訳辞書パターンを使うか」（社員／アルバイト／アルバイト社保加入 等）を覚えておく表
create table if not exists payroll_journal_assignments (
  user_id uuid primary key references users(id),
  tenant_id text not null default 'default',
  template_id uuid references mf_journal_templates(id),
  updated_by uuid references users(id),
  updated_at timestamptz not null default now()
);
alter table payroll_journal_assignments enable row level security;
drop policy if exists pja_all on payroll_journal_assignments;
create policy pja_all on payroll_journal_assignments for all
  using (invoice_can_access()) with check (invoice_can_access());

-- 月ごとに誰の給与仕訳をいつ・どの伝票番号で登録したか（重複登録防止・履歴）
create table if not exists payroll_journal_records (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id),
  year_month text not null,          -- sf_payroll_syncと同じ'YYYY-MM'形式
  tenant_id text not null default 'default',
  template_id uuid references mf_journal_templates(id),
  mf_journal_id text,
  mf_journal_number bigint,
  mf_journal_created_at timestamptz,
  invoice_id uuid references invoices(id), -- create_standaloneで作られるinvoices行（証憑・監査ログ経由の記録用）
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  unique (user_id, year_month)
);
alter table payroll_journal_records enable row level security;
drop policy if exists pjr_all on payroll_journal_records;
create policy pjr_all on payroll_journal_records for all
  using (invoice_can_access()) with check (invoice_can_access());
