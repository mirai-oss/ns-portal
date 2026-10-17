-- =====================================================================
-- 所属のズレ（管理システム⇔スマレジ）の現在の一覧と、未読バッジ用の件数（担当D・2026-10-17）
-- smaregi-affiliation-sync が毎回の実行で作り直す（試行モードでも更新する）。画面（nippoの「所属のズレ」・ポータル）はこのRPCを読む。
-- 【影響】新規テーブル1つ・関数1つの追加のみ。既存は変更しない。氏名は表に持たず、RPC（CEO/HQのみ）で結合して返す。
-- 【rollback】 drop function if exists public.hq_staff_store_mismatch(); drop table if exists public.staff_store_mismatch;
-- =====================================================================
create table if not exists public.staff_store_mismatch (
  user_id uuid not null references public.users(id) on delete cascade,
  contract_id text not null,
  only_portal text[] not null default '{}',     -- 管理システムにだけある所属（店舗名）
  only_smaregi text[] not null default '{}',    -- スマレジにだけある所属（店舗名）
  reason text,                                  -- 見送り理由など（空＝通常のズレ）
  detected_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, contract_id)
);
alter table public.staff_store_mismatch enable row level security;
revoke all on public.staff_store_mismatch from anon, authenticated;

-- CEO/HQ向け: 今ズレている人の一覧（件数＝バッジの数字は count）
create or replace function public.hq_staff_store_mismatch()
returns table (user_id uuid, user_name text, contract_id text, contract_label text, only_portal text[], only_smaregi text[], reason text, detected_at timestamptz, total_count bigint)
language sql stable security definer set search_path = public as $$
  select m.user_id, u.name, m.contract_id, c.label, m.only_portal, m.only_smaregi, m.reason, m.detected_at,
         count(*) over () as total_count
  from public.staff_store_mismatch m
  join public.users u on u.id = m.user_id
  left join public.smaregi_contracts c on c.contract_id = m.contract_id
  where public.hq_can_manage() and u.is_active
  order by m.detected_at, u.name;
$$;
revoke all on function public.hq_staff_store_mismatch() from public, anon;
grant execute on function public.hq_staff_store_mismatch() to authenticated;
