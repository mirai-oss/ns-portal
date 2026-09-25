-- 現金売上の月次照合（2026-09-26・ユーザー要望）
-- 毎月3日にMac mini(ns-daily-import/tasks/cash-sales-monthly-check.js)が前月分をレジ(Dinii/ZeroRegi)から取り直し、
-- 管理システム（売上DB「支払いDB」）の現金売上と店舗×日で照合した結果をここへ保存する。
-- 全店舗一致したら会計側(ar_receivables)へ「現金売上」の入金候補を作り、MF仕訳（仕訳辞書）へ進める。
-- 差異があればポータルの「現金売上照合」画面で店舗×日×金額を表示し、「レジに合わせて修正」を依頼→
-- Mac miniが売上DBを書き換える（cash_recon_fix_requests）。
--
-- 【影響】新規テーブル追加のみ。既存テーブル・ジョブは変更しない。
-- 【rollback】 drop table if exists public.cash_recon_fix_requests, public.cash_recon_items, public.cash_recon_runs;
-- 閲覧・依頼できるのは有効なマスター／CEO／HQのみ（書き込みはMac miniのservice_key）。

create table if not exists public.cash_recon_runs (
  id uuid primary key default gen_random_uuid(),
  target_ym text not null,                      -- 'YYYY-MM'（照合した月）
  status text not null default 'running',       -- running / matched(全店舗一致) / mismatch(差異あり) / error
  triggered_by text not null default 'schedule',-- schedule / portal / manual
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  store_count int,
  matched_stores int,
  diff_stores int,
  error text,
  note text
);
create index if not exists cash_recon_runs_ym_idx on public.cash_recon_runs (target_ym, started_at desc);

create table if not exists public.cash_recon_items (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.cash_recon_runs(id) on delete cascade,
  target_ym text not null,
  store_name text not null,                     -- 正式名（stores.name）
  store_id uuid references public.stores(id),
  business_date date not null,
  mgmt_cash numeric,                            -- 管理システム(支払いDB)の現金。null=その日の行が無い
  pos_cash numeric,                             -- レジの現金。null=レジ側にその日の行が無い
  diff numeric generated always as (coalesce(pos_cash, 0) - coalesce(mgmt_cash, 0)) stored, -- レジ − 管理システム
  status text not null,                         -- ok / diff / missing_mgmt / missing_pos
  mgmt_store_raw text,                          -- 支払いDB上の店舗名の表記（修正時に既存行を探すキー。表記ゆれで二重追加しないため）
  mgmt_row int,                                 -- 支払いDBのシート行番号（参考。修正時の照合は店舗名×日で行う）
  mgmt_values jsonb,                            -- 支払いDBの数値16列（修正前の管理システム側）
  pos_values jsonb,                             -- レジの数値16列（修正時に書き戻す正しい値）
  pos_source text,                              -- dinii-ns / dinii-nstyle / zeroregi
  fetched_at timestamptz not null default now(),
  fix_status text,                              -- null / requested / fixed / failed
  fixed_at timestamptz
);
create index if not exists cash_recon_items_run_idx on public.cash_recon_items (run_id, store_name, business_date);
create index if not exists cash_recon_items_ym_idx on public.cash_recon_items (target_ym, status);

create table if not exists public.cash_recon_fix_requests (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.cash_recon_runs(id) on delete cascade,
  store_name text,                              -- null=差異のある全店舗
  business_date date,                           -- null=差異のある全日
  requested_by uuid default auth.uid(),
  requested_at timestamptz not null default now(),
  status text not null default 'pending',       -- pending / running / success / failed
  started_at timestamptz,
  finished_at timestamptz,
  result text
);
create index if not exists cash_recon_fix_requests_status_idx on public.cash_recon_fix_requests (status, requested_at);
-- 同じ照合結果に対する未完了の修正依頼は1つだけ（連打・二重書き換え防止）
create unique index if not exists cash_recon_fix_one_open_per_run
  on public.cash_recon_fix_requests (run_id) where status in ('pending', 'running');

alter table public.cash_recon_runs enable row level security;
alter table public.cash_recon_items enable row level security;
alter table public.cash_recon_fix_requests enable row level security;

drop policy if exists cash_recon_runs_select_hq on public.cash_recon_runs;
create policy cash_recon_runs_select_hq on public.cash_recon_runs for select to authenticated
  using (exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO', 'HQ'))));

drop policy if exists cash_recon_items_select_hq on public.cash_recon_items;
create policy cash_recon_items_select_hq on public.cash_recon_items for select to authenticated
  using (exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO', 'HQ'))));

drop policy if exists cash_recon_fix_requests_select_hq on public.cash_recon_fix_requests;
create policy cash_recon_fix_requests_select_hq on public.cash_recon_fix_requests for select to authenticated
  using (exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO', 'HQ'))));

drop policy if exists cash_recon_fix_requests_insert_hq on public.cash_recon_fix_requests;
create policy cash_recon_fix_requests_insert_hq on public.cash_recon_fix_requests for insert to authenticated
  with check (
    status = 'pending' and requested_by = auth.uid()
    and exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO', 'HQ')))
  );
