-- 2026-08-30 担当B（nippo）続き
-- ユーザー要望: 「給与・インセンティブ配分」画面で、その月にいない従業員を
-- 一覧・入力の両方から非表示にできるように（間違えたときのため復活もできるように）。
create table if not exists sf_payroll_hidden (
  user_id uuid not null references users(id) on delete cascade,
  year_month text not null, -- 'YYYY-MM'
  hidden_by uuid references users(id),
  hidden_at timestamptz not null default now(),
  primary key (user_id, year_month)
);
comment on table sf_payroll_hidden is '給与・インセンティブ配分画面で、その月だけ従業員を一覧・入力から非表示にする設定。2026-08-30追加';

alter table sf_payroll_hidden enable row level security;
create policy sf_payroll_hidden_read on sf_payroll_hidden for select using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.is_master)
  or has_feature(auth.uid(), 'labor_cost_view')
);
create policy sf_payroll_hidden_write on sf_payroll_hidden for all using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.is_master)
) with check (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.is_master)
);
