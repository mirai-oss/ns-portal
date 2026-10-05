-- 【事前報告様式（DB変更）】
-- 目的: 担当Aの依頼（2026-10-06）。PLと媒体別売上を GAS(bqGetPL/bqGetSpot/bqGetLoanPrincipal/bqGetMedia) なしで描くための
--       「行レベル」ミラー4つを追加する（stg_* のSupabase側ミラー。編集・保存は従来どおりGAS→シート→BQが正）。
--   kd_media_daily  = stg_media（店舗×日×媒体の客数/客組数/純売上）。24か月ぶん約2万行
--   kd_pl_entries   = stg_pl（年月・店舗・勘定科目・区分・金額・メモ・補助科目）。店舗名が空=全社共通
--   kd_spot_entries = stg_spot（スポット人件費。日付・店舗・区分・金額・人数・メモ・ID）
--   kd_loan_entries = stg_loan_principal（借入返済元金。年月・店舗・法人・元金・メモ）
-- 影響: 新規テーブル追加のみ（既存テーブル・既存の列・既存RLSは変更なし）。値はkeiei-kd-refreshが元データから作り直す派生データ
--       （壊れたら捨てて再作成可能）。読み出しはkeiei-api-dashboard-summary(service_role+自前の権限判定)。RLSは他のkd_と同じ。
-- ロールバック: drop table kd_media_daily, kd_pl_entries, kd_spot_entries, kd_loan_entries; drop function kd_replace_entries;
-- 実行: supabase db query --linked -f supabase/2026-10-06_kd_entries_media_daily.sql

-- ---------------------------------------------------------------------
-- kd_media_daily（主キー相当: store_id, biz_date, media_raw ※media_rawは元の媒体名のまま。media_nameはtpl_media_aliasで正規化した名前）
-- ---------------------------------------------------------------------
create table if not exists public.kd_media_daily (
  id bigint generated always as identity primary key,
  store_id uuid not null references public.stores (id),
  biz_date date not null,
  media_raw text not null,
  media_name text not null,
  guests numeric not null default 0,
  parties numeric not null default 0,
  net_sales numeric not null default 0,
  computed_at timestamptz not null default now(),
  source_count int not null default 0,
  sync_run_id uuid references public.kd_sync_runs (id)
);
create unique index if not exists kd_media_daily_unique on public.kd_media_daily (store_id, biz_date, media_raw);
create index if not exists kd_media_daily_date_idx on public.kd_media_daily (biz_date desc);

-- ---------------------------------------------------------------------
-- kd_pl_entries / kd_spot_entries / kd_loan_entries（毎回まるごと入れ替え。store_idは店舗名が既知の店舗に解決できた時だけ入る。
--   店舗名が空=全社共通は store_id=null・store_name=''。解決できない店舗名は store_id=null・store_name=元の名前のまま残す＝行は絶対に落とさない）
-- ---------------------------------------------------------------------
create table if not exists public.kd_pl_entries (
  id bigint generated always as identity primary key,
  year_month text not null,
  store_id uuid references public.stores (id),
  store_name text not null default '',
  item text not null default '',
  category text not null default '',
  amount numeric not null default 0,
  memo text not null default '',
  sub_item text not null default '',
  computed_at timestamptz not null default now(),
  sync_run_id uuid references public.kd_sync_runs (id)
);
create index if not exists kd_pl_entries_ym_idx on public.kd_pl_entries (year_month desc);

create table if not exists public.kd_spot_entries (
  id bigint generated always as identity primary key,
  spot_id text not null default '',
  work_date date not null,
  store_id uuid references public.stores (id),
  store_name text not null default '',
  kind text not null default '',
  amount numeric not null default 0,
  headcount numeric,
  memo text not null default '',
  entered_by text not null default '',
  entered_at text not null default '',
  computed_at timestamptz not null default now(),
  sync_run_id uuid references public.kd_sync_runs (id)
);
create index if not exists kd_spot_entries_date_idx on public.kd_spot_entries (work_date desc);

create table if not exists public.kd_loan_entries (
  id bigint generated always as identity primary key,
  year_month text not null,
  store_id uuid references public.stores (id),
  store_name text not null default '',
  corp_name text not null default '',
  principal numeric not null default 0,
  memo text not null default '',
  computed_at timestamptz not null default now(),
  sync_run_id uuid references public.kd_sync_runs (id)
);
create index if not exists kd_loan_entries_ym_idx on public.kd_loan_entries (year_month desc);

-- RLS（他のkd_と同じ。APIはservice_role+自前スコープ判定で読む。全社共通行(store_id null)はCEO/HQ/TEAM/masterのみ直接参照可）
do $$
declare t text;
begin
  foreach t in array array['kd_media_daily','kd_pl_entries','kd_spot_entries','kd_loan_entries'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select', t);
    execute format($p$create policy %I on public.%I for select to authenticated using (
      exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (
        u.is_master or u.role in ('CEO','HQ','TEAM')
        or (u.role = 'TENCHO' and %I.store_id is not null and exists (select 1 from public.user_stores us where us.user_id = u.id and us.store_id = %I.store_id))
      ))
    )$p$, t || '_select', t, t, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- まるごと入れ替え（1トランザクション＝読む側に「消えた状態」「二重に見える状態」を一瞬も見せない）。service_roleだけが実行可。
-- ---------------------------------------------------------------------
create or replace function public.kd_replace_entries(p_table text, p_rows jsonb, p_run uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare n integer;
begin
  if p_table = 'kd_pl_entries' then
    delete from public.kd_pl_entries where true;
    insert into public.kd_pl_entries (year_month, store_id, store_name, item, category, amount, memo, sub_item, sync_run_id)
      select year_month, store_id, coalesce(store_name,''), coalesce(item,''), coalesce(category,''), coalesce(amount,0), coalesce(memo,''), coalesce(sub_item,''), p_run
      from jsonb_to_recordset(p_rows) as x(year_month text, store_id uuid, store_name text, item text, category text, amount numeric, memo text, sub_item text);
  elsif p_table = 'kd_spot_entries' then
    delete from public.kd_spot_entries where true;
    insert into public.kd_spot_entries (spot_id, work_date, store_id, store_name, kind, amount, headcount, memo, entered_by, entered_at, sync_run_id)
      select coalesce(spot_id,''), work_date, store_id, coalesce(store_name,''), coalesce(kind,''), coalesce(amount,0), headcount, coalesce(memo,''), coalesce(entered_by,''), coalesce(entered_at,''), p_run
      from jsonb_to_recordset(p_rows) as x(spot_id text, work_date date, store_id uuid, store_name text, kind text, amount numeric, headcount numeric, memo text, entered_by text, entered_at text);
  elsif p_table = 'kd_loan_entries' then
    delete from public.kd_loan_entries where true;
    insert into public.kd_loan_entries (year_month, store_id, store_name, corp_name, principal, memo, sync_run_id)
      select year_month, store_id, coalesce(store_name,''), coalesce(corp_name,''), coalesce(principal,0), coalesce(memo,''), p_run
      from jsonb_to_recordset(p_rows) as x(year_month text, store_id uuid, store_name text, corp_name text, principal numeric, memo text);
  else
    raise exception 'kd_replace_entries: 未対応のテーブル %', p_table;
  end if;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.kd_replace_entries(text, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.kd_replace_entries(text, jsonb, uuid) to service_role;

comment on table public.kd_media_daily is 'stg_media(店舗×日×媒体)のミラー。keiei-kd-refresh op=media_monthly/entries が洗い替え。経営D 媒体別売上・広告管理・営業区分(媒体基準)用';
comment on table public.kd_pl_entries is 'stg_pl行ミラー。store_name空=全社共通。keiei-kd-refresh op=pl_monthly/entries が毎回まるごと入れ替え（kd_replace_entries）';
comment on table public.kd_spot_entries is 'stg_spot行ミラー（スポット人件費）。keiei-kd-refresh op=store_monthly/entries が毎回まるごと入れ替え';
comment on table public.kd_loan_entries is 'stg_loan_principal行ミラー（借入返済元金）。keiei-kd-refresh op=pl_monthly/entries が毎回まるごと入れ替え';
