-- 仕訳辞書（管理システム内で登録・編集・削除できる仕訳テンプレート）2026-08-31
--
-- 背景: マネーフォワードの正式な外部連携API（v3）には「仕訳辞書」を取得するAPIが
-- 存在しない（内部の非公式APIを使えば可能だが、規約違反リスクがあるため不採用。
-- 2026-08-31にユーザーへ確認済み）。代わりに、よく使う仕訳パターンを
-- 管理システム自身のDBに保存し、invoices.htmlの仕訳作成画面から選べるようにする。
--
-- 1テンプレート = 複数の明細行（branches）を持てる（振替伝票・複合仕訳に対応）。
-- branchesの中身はmf-journal Edge Functionの「create」action・過去の仕訳検索(list_journals)結果と
-- 同じ形（{debit:{account_id,account_name,sub_account_id,sub_account_name}, credit:{...},
--          department_id, department_name, amount, remark}の配列）に揃えている。
create table if not exists mf_journal_templates (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null default 'default', -- 'default'=有限会社トーホーエージェンシー・'nstyle'=株式会社N-Style等
  label text not null,                        -- 例:「【未払金】アルバイト給与（川崎）」
  branches jsonb not null,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists mf_journal_templates_tenant_idx on mf_journal_templates(tenant_id, label);

alter table mf_journal_templates enable row level security;
drop policy if exists mfjt_all on mf_journal_templates;
create policy mfjt_all on mf_journal_templates for all
  using (invoice_can_access()) with check (invoice_can_access());
