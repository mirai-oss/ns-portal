-- 引き落とし・他行振込の自動照合（2026-10-16 担当C）
-- ①覚えさせた「摘要の名前⇔請求先」 ②照合候補（定期実行が作る・人が確認して振込済みにする） ③定期実行の実行履歴
create table if not exists public.payment_match_rules (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null,
  tenant_id text not null default 'default',
  pattern text not null,            -- 摘要・補助科目に含まれる名前（数字・日付を除いて正規化したもの）
  sample_remark text,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (vendor_id, tenant_id, pattern)
);
create table if not exists public.payment_match_candidates (
  id uuid primary key default gen_random_uuid(),
  cand_key text not null unique,    -- kind|tenant|journal_id|invoice_ids（同じ候補を重複して作らない・通知を繰り返さない）
  kind text not null check (kind in ('single','bundle','mismatch')),
  tenant_id text not null default 'default',
  invoice_ids uuid[] not null,
  journal_id text,
  transaction_date date,
  outflow_amount numeric,
  invoice_total numeric,
  diff numeric,
  score int,
  reasons text[],
  summary text,
  remark text,
  status text not null default 'pending' check (status in ('pending','confirmed','dismissed')),
  notified_at timestamptz,
  decided_by uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists payment_match_candidates_status_idx on public.payment_match_candidates(status);
create table if not exists public.payment_scan_runs (
  id uuid primary key default gen_random_uuid(),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  trigger text,
  ok boolean,
  summary jsonb
);
alter table public.payment_match_rules enable row level security;
alter table public.payment_match_candidates enable row level security;
alter table public.payment_scan_runs enable row level security;
drop policy if exists payment_match_rules_all_inv on public.payment_match_rules;
create policy payment_match_rules_all_inv on public.payment_match_rules for all using (invoice_can_access()) with check (invoice_can_access());
drop policy if exists payment_match_candidates_all_inv on public.payment_match_candidates;
create policy payment_match_candidates_all_inv on public.payment_match_candidates for all using (invoice_can_access()) with check (invoice_can_access());
drop policy if exists payment_scan_runs_read_inv on public.payment_scan_runs;
create policy payment_scan_runs_read_inv on public.payment_scan_runs for select using (invoice_can_access());
