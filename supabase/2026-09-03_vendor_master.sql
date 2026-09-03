-- 取引先マスタ・取引先銀行口座・口座変更申請（会計・請求書処理の全面刷新 フェーズA-1〜A-3・2026-09-03）
--
-- ユーザー要望「取引先マスタと仕訳辞書は分ける」「支払先/銀行口座の登録済み口座・現在有効な口座・
-- 過去口座・最終確認日・変更履歴を確認できるように」「振込先口座変更は仕訳辞書やAIで自動更新せず、
-- 振込先口座変更として要確認に回す」に対応する新規テーブル3本。
--
-- vendor_name（invoicesの自由入力列）とは別に、正規化された取引先エンティティを持つことで、
-- ①同じ取引先の表記ゆれをまとめる②取引先ごとに銀行口座・仕訳辞書の既定値を紐付ける
-- ③口座変更の履歴管理・要確認フローを実現する、の3つを可能にする。

-- ① 取引先マスタ
create table if not exists vendors (
  id uuid primary key default gen_random_uuid(),
  name text not null,                          -- 正式名称
  name_aliases text[] not null default '{}',   -- 表記ゆれ・別名（あいまい一致用）
  corporation_number text,                     -- 法人番号
  contact_email text,
  contact_phone text,
  default_corporation_id uuid references corporations(id),  -- 通常請求される法人（ヒント）
  default_store_id uuid references stores(id),               -- 通常請求される店舗（ヒント）
  mf_partner_name text,                        -- マネーフォワード側の取引先名（あれば）
  infomart_partner_id text,                    -- Infomart取引先ID（あれば・将来のInfomart連携用）
  notes text,
  is_active boolean not null default true,
  created_by uuid references users(id),
  updated_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table vendors enable row level security;
drop policy if exists vendors_all on vendors;
create policy vendors_all on vendors for all
  using (invoice_can_access()) with check (invoice_can_access());
create index if not exists vendors_name_idx on vendors(name);

-- ② 取引先銀行口座（payroll_bank_accountsは従業員専用＝PKがuser_idのため流用できない。
-- vendor向けに複製し、1取引先が複数口座・過去口座の履歴を持てるようにPKをidにする）
create table if not exists vendor_bank_accounts (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references vendors(id),
  bank_code text,
  bank_name text,
  branch_code text,
  branch_name text,
  account_type text not null default '1' check (account_type in ('1','2','4')), -- 1=普通 2=当座 4=貯蓄
  account_number text,
  account_holder_kana text,
  is_current boolean not null default true,   -- 現在有効な口座か
  valid_from date not null default current_date,
  valid_to date,                               -- 過去口座になった日（is_current=falseになった日）
  source text not null default 'manual' check (source in ('manual','invoice_extract')),
  confirmed_at timestamptz,                    -- 最終確認日
  confirmed_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- 銀行口座番号を扱うため、payroll_bank_accountsと同じくマスター/HQ限定ポリシー（invoice_can_accessより厳格）
alter table vendor_bank_accounts enable row level security;
drop policy if exists vba_all on vendor_bank_accounts;
create policy vba_all on vendor_bank_accounts for all
  using (coalesce((select u.is_master or u.role in ('CEO','HQ') from users u where u.id = auth.uid() and u.is_active), false))
  with check (coalesce((select u.is_master or u.role in ('CEO','HQ') from users u where u.id = auth.uid() and u.is_active), false));
create index if not exists vba_vendor_idx on vendor_bank_accounts(vendor_id);
create unique index if not exists vba_current_unique on vendor_bank_accounts(vendor_id) where is_current;

-- ③ 口座変更申請（請求書から抽出した口座が登録済み口座と異なる場合、自動更新せず要確認に回す）
create table if not exists vendor_bank_account_change_requests (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references vendors(id),
  invoice_id uuid references invoices(id),     -- どの請求書がきっかけで検知したか
  proposed_bank_name text,
  proposed_branch_name text,
  proposed_account_type text,
  proposed_account_number text,
  proposed_account_holder_kana text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
alter table vendor_bank_account_change_requests enable row level security;
drop policy if exists vbacr_all on vendor_bank_account_change_requests;
create policy vbacr_all on vendor_bank_account_change_requests for all
  using (coalesce((select u.is_master or u.role in ('CEO','HQ') from users u where u.id = auth.uid() and u.is_active), false))
  with check (coalesce((select u.is_master or u.role in ('CEO','HQ') from users u where u.id = auth.uid() and u.is_active), false));
create index if not exists vbacr_vendor_idx on vendor_bank_account_change_requests(vendor_id);
create index if not exists vbacr_status_idx on vendor_bank_account_change_requests(status);
