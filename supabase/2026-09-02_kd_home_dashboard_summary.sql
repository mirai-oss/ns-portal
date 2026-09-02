-- W2④（設計書_表示集計層kdと高速化実行計画_2026-09-02.md §3/§4/§10.1・レーンP所有）
-- kd_dashboard_daily_summary: 経営ダッシュボード初回表示用の store×日 事前集計（売上・客数・組数等）。
-- kd_home_kpi_snapshot: ホーム画面用の store×日 KPIスナップショット（当日実績・月累計・予算達成率等）。
-- 書き込みはkeiei-kd-refresh（service_role・op=dashboard_daily / op=home_kpi）のみ。
--
-- 【データ出典についての注記（2026-09-02実装時点）】net_sales/guests/parties/cost/laborは
-- tori-dashboard GASの軽量アクション`bqDailyStoreForSync`（BQ_LOAD_TOKEN認証・ログイン不要・
-- 既にdash-sync/D-3等が使っている既存の読み取り専用エンドポイント。GASコード自体は無変更）から取得。
-- ランチ/ディナー内訳・決済別内訳は出典データ未特定（stg_media時間帯別 or POS決済データの追加調査が
-- 必要）のため、当面はnull/空jsonbのまま列だけ用意する。列自体は設計書§3どおり作り、埋まり次第
-- リフレッシュジョブ側だけ直せば良いようにしてある。

create table if not exists public.kd_dashboard_daily_summary (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id),
  corporation_id uuid references public.corporations (id),
  period_date date not null,
  net_sales numeric,
  guests int,
  parties int,
  avg_check numeric,                                  -- 客単価＝net_sales/guests（guests=0はnull）
  lunch_dinner_breakdown jsonb not null default '{}'::jsonb,  -- {"lunch":{"sales":n,"guests":n},"dinner":{...}}（未実装・出典調査中）
  payment_breakdown jsonb not null default '{}'::jsonb,       -- {"cash":n,"card":n,...}（未実装・出典調査中。cashのみ将来埋められる）
  prior_year_same_weekday_sales numeric,               -- 前年同曜日の売上（本テーブルの蓄積が1年分溜まってから埋まる）
  prior_year_same_weekday_ratio numeric,               -- 今年/前年（前年値が無い間はnull）
  source_updated_at timestamptz,
  computed_at timestamptz not null default now(),
  source_count int not null default 0,
  sync_run_id uuid references public.kd_sync_runs (id)
);
create unique index if not exists kd_dashboard_daily_summary_unique on public.kd_dashboard_daily_summary (store_id, period_date);
create index if not exists kd_dashboard_daily_summary_period_idx on public.kd_dashboard_daily_summary (period_date desc);
create index if not exists kd_dashboard_daily_summary_corp_period_idx on public.kd_dashboard_daily_summary (corporation_id, period_date);

alter table public.kd_dashboard_daily_summary enable row level security;
drop policy if exists kd_dashboard_daily_summary_select on public.kd_dashboard_daily_summary;
create policy kd_dashboard_daily_summary_select on public.kd_dashboard_daily_summary
  for select to authenticated using (
    exists (
      select 1 from public.users u
      where u.id = auth.uid() and u.is_active and (
        u.is_master or u.role in ('CEO', 'HQ', 'TEAM')
        or (u.role = 'TENCHO' and exists (
              select 1 from public.user_stores us where us.user_id = u.id and us.store_id = kd_dashboard_daily_summary.store_id
            ))
      )
    )
  );

create table if not exists public.kd_home_kpi_snapshot (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id),
  corporation_id uuid references public.corporations (id),
  period_date date not null,
  today_sales numeric,
  today_guests int,
  today_parties int,
  mtd_sales numeric,                        -- 当月累計売上（月初〜period_date）
  budget_achievement_rate numeric,          -- mtd_sales / その月の目標累計（月次目標を日割りせず単純比較。0-1超の比率）
  daily_report_submission_rate numeric,     -- 日報提出率（未実装・出典テーブル調査中。nullのまま）
  checklist_completion_rate numeric,        -- チェック実施率（未実装・出典テーブル調査中。nullのまま）
  hq_task_overdue_count int,                -- 本部タスク滞留数（法人単位の値をその法人の全店舗行に複製）
  source_updated_at timestamptz,
  computed_at timestamptz not null default now(),
  source_count int not null default 0,
  sync_run_id uuid references public.kd_sync_runs (id)
);
create unique index if not exists kd_home_kpi_snapshot_unique on public.kd_home_kpi_snapshot (store_id, period_date);
create index if not exists kd_home_kpi_snapshot_period_idx on public.kd_home_kpi_snapshot (period_date desc);
create index if not exists kd_home_kpi_snapshot_corp_period_idx on public.kd_home_kpi_snapshot (corporation_id, period_date);

alter table public.kd_home_kpi_snapshot enable row level security;
drop policy if exists kd_home_kpi_snapshot_select on public.kd_home_kpi_snapshot;
create policy kd_home_kpi_snapshot_select on public.kd_home_kpi_snapshot
  for select to authenticated using (
    exists (
      select 1 from public.users u
      where u.id = auth.uid() and u.is_active and (
        u.is_master or u.role in ('CEO', 'HQ', 'TEAM')
        or (u.role = 'TENCHO' and exists (
              select 1 from public.user_stores us where us.user_id = u.id and us.store_id = kd_home_kpi_snapshot.store_id
            ))
      )
    )
  );
