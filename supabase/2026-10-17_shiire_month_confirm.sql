-- 【事前報告様式（DB変更）】TK-222 仕入高の月次確定（設計書_請求書メール自動処理 §12・Sync13）
-- 目的: 経営PLの原価（cost_auto）は infomart-siire の速報（店舗合計）。承認済み請求書の仕入高を請求書単位でPLへ入れると二重になるため、
--       「店舗×月の承認済み請求書の仕入高合計」で kd_pl_monthly_summary の cost_auto を『月次確定』として置き換える（確定=担当Cのトリガー）。
-- 追加（新規のみ・既存の列/テーブル/RLSは変更なし）:
--   shiire_month_confirmations … 店舗×月の「仕入の請求書が全社分そろい承認済み」確定の記録（担当Cが全社承認完了時に confirmed=true）。vendor_total=その月の想定取引先数（「確定 n/全社」の全社）
--   v_shiire_approved_monthly   … 承認済み請求書の仕入高を 店舗×月×取引先 に集計する読み取り専用ビュー（journal_draft.debit_lines の勘定科目=仕入高・税抜優先）
--   kd_pl_monthly_summary に列追加: shiire_status('confirmed'|'partial')・shiire_vendors_approved・shiire_vendors_total・shiire_invoice_amount・cost_auto_siire(置換前の速報値)
-- 影響: 既存の値は変わらない。置換は app_secrets.shiire_confirm_enabled='1' かつ shiire_month_confirmations.confirmed=true の店舗×月だけ（既定は無効＝何も起きない）。
--       精算書店舗(4店舗)は対象外（§11-3・原価0が正常）。派生テーブルは壊れても再作成可能。
-- ロールバック: update app_secrets… shiire_confirm_enabled を消す（次回の更新で置換前に戻る）／drop view v_shiire_approved_monthly; drop table shiire_month_confirmations; alter table kd_pl_monthly_summary drop column …
-- 実行: supabase db query --linked -f supabase/2026-10-17_shiire_month_confirm.sql

create table if not exists public.shiire_month_confirmations (
  id bigint generated always as identity primary key,
  store_id uuid not null references public.stores (id),
  year_month text not null check (year_month ~ '^\d{4}-(0[1-9]|1[0-2])$'),
  confirmed boolean not null default false,        -- true=この店舗×月の仕入高は請求書で確定（全社分承認済み）
  vendor_total int,                                 -- 想定取引先数（「確定 n/全社」の全社）。未定ならnull
  note text,
  confirmed_at timestamptz, confirmed_by text,
  updated_at timestamptz not null default now(), updated_by text,
  unique (store_id, year_month)
);
alter table public.shiire_month_confirmations enable row level security;
drop policy if exists shiire_month_confirmations_select on public.shiire_month_confirmations;
create policy shiire_month_confirmations_select on public.shiire_month_confirmations for select to authenticated using (
  exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ','TEAM')))
);
drop policy if exists shiire_month_confirmations_write on public.shiire_month_confirmations;
create policy shiire_month_confirmations_write on public.shiire_month_confirmations for all to authenticated
  using (exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ'))))
  with check (exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ'))));

-- 承認済み = 承認以降の工程（approved/payment_waiting/paid/completed）かつMF仕訳が登録済みかつ取消でない。
-- 月 = 対象月(target_year_month)、無ければ仕訳の取引日(transaction_date)の月。金額 = 税抜(net_amount)優先、無ければ税込(amount)で has_net=false。
create or replace view public.v_shiire_approved_monthly as
select
  (l->>'store_id')::uuid as store_id,
  to_char(coalesce(i.target_year_month,
    case when i.journal_draft->>'transaction_date' ~ '^\d{4}-\d{2}-\d{2}' then (i.journal_draft->>'transaction_date')::date end), 'YYYY-MM') as year_month,
  i.vendor_id, i.id as invoice_id, i.vendor_name,
  sum(coalesce(nullif(l->'debit'->>'net_amount','')::numeric, nullif(l->'debit'->>'amount','')::numeric)) as net_amount,
  sum(coalesce(nullif(l->'debit'->>'amount','')::numeric, 0)) as gross_amount,
  bool_and(nullif(l->'debit'->>'net_amount','') is not null) as has_net
from public.invoices i
cross join lateral jsonb_array_elements(coalesce(i.journal_draft->'debit_lines', '[]'::jsonb)) l
where i.current_stage in ('approved','payment_waiting','paid','completed')
  and i.invoice_status <> 'cancelled'
  and i.mf_journal_id is not null
  and l->'debit'->>'account' = '仕入高'
  and nullif(l->>'store_id','') is not null
  -- 精算書ルート（担当C・invoice-checkが checks->'routes' に付与）の行は除外＝精算書→PLで入るため二重計上になる。
  -- 黒霧屋 新横浜（2026-11-01〜運営会社LiveGate）のような使い分け店舗も、この判定で自動的に外れる。
  and coalesce((select r->>'route' from jsonb_array_elements(coalesce(i.checks->'routes','[]'::jsonb)) r where r->>'store_id' = l->>'store_id' limit 1), 'pl') <> 'seisan'
  -- 精算書の対象店舗（stores.seisan_target / seisan_pl_categories_target）も対象外（§11-3）
  and not exists (select 1 from public.stores st where st.id = (l->>'store_id')::uuid and (coalesce(st.seisan_target, false) or coalesce(st.seisan_pl_categories_target, false)))
group by 1, 2, 3, 4, 5;
revoke all on public.v_shiire_approved_monthly from public, anon, authenticated;
grant select on public.v_shiire_approved_monthly to service_role;

alter table public.kd_pl_monthly_summary
  add column if not exists shiire_status text,                 -- 'confirmed'(請求書で確定・cost_autoを置換済み) | 'partial'(承認済みはあるが未確定・置換せず)
  add column if not exists shiire_vendors_approved int,        -- 「確定 n/全社」のn（承認済み仕入高のある取引先数）
  add column if not exists shiire_vendors_total int,           -- 「確定 n/全社」の全社（shiire_month_confirmations.vendor_total。未定ならnull）
  add column if not exists shiire_invoice_amount numeric,      -- 承認済み請求書の仕入高合計（税抜優先）
  add column if not exists cost_auto_siire numeric;            -- 置換前のsiire速報値（確定月のみ。差=shiire_invoice_amount−cost_auto_siire の検算用）
comment on column public.kd_pl_monthly_summary.shiire_status is 'TK-222 仕入高の月次確定。confirmed=cost_autoを承認済み請求書の仕入高合計で置換済み';

-- 追記（2026-10-17・担当A確認）: 店舗月次(kd_store_monthly_summary: 原価率・FL率・粗利。ホームKPIが使用)も確定月は同じ請求書合計で置換し、PLと食い違わせない
alter table public.kd_store_monthly_summary
  add column if not exists shiire_status text,
  add column if not exists cost_siire numeric;     -- 置換前のsiire速報の原価（確定月のみ）
