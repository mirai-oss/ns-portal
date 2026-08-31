-- 給与振込先口座（C-7④・2026-08-31）
-- PayPay銀行WEB総振CSVを生成するために必要な、従業員ごとの振込先口座情報。
-- info.employees/info.employee_salariesには銀行口座の列が存在しないため新規に用意する。
-- 非常にセンシティブな情報（銀行口座）のため、閲覧・編集ともmaster/HQのみに限定する
-- （payroll-pdfsバケットのRLS方針と同じ考え方）。
create table if not exists payroll_bank_accounts (
  user_id uuid primary key references users(id),
  bank_code text not null,          -- 銀行コード（4桁・数字のみ）
  bank_name text,                   -- 表示用（任意・振込データ自体には使わない）
  branch_code text not null,        -- 支店コード（3桁・数字のみ）
  branch_name text,                 -- 表示用（任意）
  account_type text not null default '1' check (account_type in ('1','2','4')), -- 1=普通 2=当座 4=貯蓄
  account_number text not null,     -- 口座番号（数字のみ・最大7桁）
  account_holder_kana text not null, -- 受取人名＝口座名義（半角カタカナ）
  updated_by uuid references users(id),
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
alter table payroll_bank_accounts enable row level security;
drop policy if exists pba_all on payroll_bank_accounts;
create policy pba_all on payroll_bank_accounts for all using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role = 'HQ'))
) with check (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role = 'HQ'))
);
