-- W2②（設計書_表示集計層kdと高速化実行計画_2026-09-02.md §3/§4/§10.1・レーンP所有）
-- kd_reservation_daily_summary: 予約の store×日 事前集計。予約分析タブ（キャンセル集計・月次サマリ）
-- は毎回rsv_reservationsの明細を全件スキャンする代わりにこの小さな事前集計を読む（軽量化ルール①⑤）。
-- 予約帳（1件ずつの明細一覧）は引き続きrsv_reservationsを直接読む（keiei-api-reservation mode:'list'。
-- 期間・limit必須で全件返しを禁止）。
-- 書き込みはkeiei-kd-refresh（service_role・op=reservation_daily）のみ。

create table if not exists public.kd_reservation_daily_summary (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id),
  corporation_id uuid references public.corporations (id),
  period_date date not null,
  reservation_count int not null default 0,        -- 来店予定+来店済み（キャンセル除く）の組数
  party_size_sum int not null default 0,            -- 同・人数
  same_day_count int not null default 0,            -- 当日予約（作成日=来店日）の組数
  same_day_party int not null default 0,
  walkin_count int not null default 0,              -- ウォークイン扱いの組数（受付窓口がウォークイン系）
  walkin_party int not null default 0,
  cancel_breakdown jsonb not null default '{}'::jsonb,   -- {"user":{"count":n,"party":n},"other":{...},"store":{...},"noshow":{...}}
  channel_breakdown jsonb not null default '{}'::jsonb,  -- {"<受付窓口名>":{"count":n,"party":n}, ...}（キャンセル除く）
  expected_sales numeric,                            -- 予約売上見込＝(reservation_count等の人数)×客単価推定（kd_dashboard_daily_summary.avg_checkが無い日はnull）
  source_updated_at timestamptz,                      -- 元データ(rsv_reservations)側の最終imported_at
  computed_at timestamptz not null default now(),
  source_count int not null default 0,                -- 集計に使ったrsv_reservations行数
  sync_run_id uuid references public.kd_sync_runs (id)
);
create unique index if not exists kd_reservation_daily_summary_unique on public.kd_reservation_daily_summary (store_id, period_date);
create index if not exists kd_reservation_daily_summary_period_idx on public.kd_reservation_daily_summary (period_date desc);
create index if not exists kd_reservation_daily_summary_corp_period_idx on public.kd_reservation_daily_summary (corporation_id, period_date);

alter table public.kd_reservation_daily_summary enable row level security;
drop policy if exists kd_reservation_daily_summary_select on public.kd_reservation_daily_summary;
-- 経営Dと同じ店舗スコープ（CEO/HQ/TEAM/マスターは全店・TENCHOはuser_storesで自店舗のみ）。
-- keiei-api-reservationのresolveScope()と同じ判定基準をSQL側でも再現（直接PostgREST読みを許可するため）。
create policy kd_reservation_daily_summary_select on public.kd_reservation_daily_summary
  for select to authenticated using (
    exists (
      select 1 from public.users u
      where u.id = auth.uid() and u.is_active and (
        u.is_master or u.role in ('CEO', 'HQ', 'TEAM')
        or (u.role = 'TENCHO' and exists (
              select 1 from public.user_stores us where us.user_id = u.id and us.store_id = kd_reservation_daily_summary.store_id
            ))
      )
    )
  );

-- 予約API3分割（keiei-api-reservation mode:'list'）の期間必須化とセットの性能索引。
-- 既存rsv_reservations（レーンI所有）へのインデックス追加のみ。列・データ・書き込み経路は無変更。
create index if not exists rsv_reservations_store_visit_idx on public.rsv_reservations (store_id, visit_date);
