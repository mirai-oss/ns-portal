-- 取引先の「支払方法（振込／引き落とし／現金）」の登録と、月ごとの一時変更（2026-10-13・ユーザー要望）
-- 「取引先ごとに振込／引き落としを1回登録したものを自動で使い、変わった月だけ変更できるようにしてほしい。
--  振込のものだけを本部タスクに、どの業者にいくら振り込みかを付けたい」
--
-- 背景: 既存の vendor_bank_accounts.payment_method は「振込先口座の行」に付く設定で、口座を登録しないと持てない
-- （インフォマート請求書の対象10社は口座未登録）。口座の有無と切り離して「取引先の支払方法」だけを持つ
-- 小さなテーブルを新設する（値の種類は vendor_bank_accounts.payment_method と同じ bank_transfer/direct_debit/cash）。
--  * vendor_payment_settings   … 取引先ごとの通常の支払方法（1取引先1行）。source=manual（人が登録）/inferred（請求書から推定）
--  * vendor_payment_overrides  … 「この月だけ」の変更（取引先×対象年月）。無ければ通常どおり
-- 参照順: overrides(対象年月) → settings → （未登録＝タスクに「要登録」として載せる）
--
-- 【影響】新規テーブル2つの追加のみ（既存テーブル・既存の振込フローは無変更）。RLSは請求書と同じ invoice_can_access()。
-- 【rollback】 drop table if exists public.vendor_payment_overrides, public.vendor_payment_settings;

create table if not exists public.vendor_payment_settings (
  vendor_id uuid primary key references public.vendors(id) on delete cascade,
  payment_method text not null check (payment_method in ('bank_transfer','direct_debit','cash')),
  source text not null default 'manual' check (source in ('manual','inferred')),
  note text,
  updated_by uuid default auth.uid(),
  updated_at timestamptz not null default now()
);

create table if not exists public.vendor_payment_overrides (
  vendor_id uuid not null references public.vendors(id) on delete cascade,
  year_month text not null check (year_month ~ '^\d{4}-\d{2}$'),
  payment_method text not null check (payment_method in ('bank_transfer','direct_debit','cash')),
  note text,
  set_by uuid default auth.uid(),
  set_at timestamptz not null default now(),
  primary key (vendor_id, year_month)
);

alter table public.vendor_payment_settings enable row level security;
alter table public.vendor_payment_overrides enable row level security;

drop policy if exists vendor_payment_settings_all on public.vendor_payment_settings;
create policy vendor_payment_settings_all on public.vendor_payment_settings
  for all to authenticated using (invoice_can_access()) with check (invoice_can_access());

drop policy if exists vendor_payment_overrides_all on public.vendor_payment_overrides;
create policy vendor_payment_overrides_all on public.vendor_payment_overrides
  for all to authenticated using (invoice_can_access()) with check (invoice_can_access());

-- updated_at自動更新
create or replace function public.vendor_payment_settings_touch() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end; $$;
drop trigger if exists vendor_payment_settings_touch on public.vendor_payment_settings;
create trigger vendor_payment_settings_touch before update on public.vendor_payment_settings
  for each row execute function public.vendor_payment_settings_touch();
