-- MF仕訳→PL連携の一般化（手数料など・ラウンド5指示書§6.1／設計書_広告費自動連携_§5・2026-09-01）
-- 広告費自動反映（ad_cost_*列・§1）と同じ骨組みの科目汎用版。
-- カード手数料・PayPay手数料などMFに会計入力した勘定科目を、店舗ごとにPLへ自動反映する。

-- PL連携対象の勘定科目リスト（設定タブで追加・削除できるようにする）。
-- 「手数料Q1」（対象科目の一覧）はユーザー回答待ちのため、設計書に明記された
-- カード手数料・PayPay手数料の受け皿として「支払手数料」を初期値に登録しておく。
create table if not exists mf_pl_fee_accounts (
  id uuid primary key default gen_random_uuid(),
  account_name text not null unique,  -- MFの勘定科目名（例: 支払手数料）
  pl_label text,                      -- PL上での表示名（省略時はaccount_nameそのまま）
  created_by uuid references users(id),
  created_at timestamptz not null default now()
);
alter table mf_pl_fee_accounts enable row level security;
drop policy if exists mpfa_all on mf_pl_fee_accounts;
create policy mpfa_all on mf_pl_fee_accounts for all
  using (invoice_can_access()) with check (invoice_can_access());
insert into mf_pl_fee_accounts (account_name, pl_label)
  values ('支払手数料','支払手数料') on conflict (account_name) do nothing;

-- 仕訳作成時に使った借方勘定科目名（PL連携対象かどうかの判定用。MF API送信には使わずメタ情報として保持）
alter table invoices add column if not exists mf_debit_accounts jsonb;

-- 広告費（ad_cost_*）と同じ形のPL反映列
alter table invoices add column if not exists pl_fee_account text;         -- 反映した勘定科目名
alter table invoices add column if not exists pl_fee_year_month date;
alter table invoices add column if not exists pl_fee_allocations jsonb;    -- [{store_id,store_name,amount,source}]
alter table invoices add column if not exists pl_fee_reflected_at timestamptz;
alter table invoices add column if not exists pl_fee_reflected_by uuid references users(id);
alter table invoices add column if not exists pl_fee_sheet_synced_at timestamptz;   -- DB_PL/BQへの反映（担当A・A-8汎用化）
alter table invoices add column if not exists pl_fee_sheet_sync_error text;
alter table invoices add column if not exists pl_fee_seisan_synced_at timestamptz;  -- 精算対象店舗の精算書への反映（担当A・A-9）
