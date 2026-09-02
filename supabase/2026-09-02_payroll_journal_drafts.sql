-- 給与仕訳プレビューの一時保存（下書き）機能（2026-09-02）
-- ユーザー要望: 「仕分けを登録してるときに、途中で消えてしまうこともあるから、一時保存で
-- ボタンを作って保存できるようにしてほしい！保存したものは、途中から修正できるようにして、
-- 登録になるまで完了にならないで欲しい！」
-- プレビュー画面での編集内容（明細行・金額・勘定科目・部門・税区分・会計計上日）を
-- まるごとJSONで保存しておき、次回このプレビューを開いたときに続きから編集できるようにする。
-- 実際にマネーフォワードへ登録（payroll_journal_records作成）されるまでは「下書き」のまま。
create table if not exists payroll_journal_drafts (
  user_id uuid not null references users(id),
  year_month text not null,          -- sf_payroll_syncと同じ'YYYY-MM'形式
  template_id uuid references mf_journal_templates(id),
  branches jsonb not null,           -- プレビュー画面のbranches配列をそのまま保存
  transaction_date date,
  updated_by uuid references users(id),
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  primary key (user_id, year_month)
);
alter table payroll_journal_drafts enable row level security;
drop policy if exists pjd_all on payroll_journal_drafts;
create policy pjd_all on payroll_journal_drafts for all
  using (invoice_can_access()) with check (invoice_can_access());
