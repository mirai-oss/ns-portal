-- レーンP: PL/売上分析/入金の月次サマリ3本（設計書_表示集計層kdと高速化実行計画_2026-09-02.md §3/§4/§10.2-1）
-- 司令塔指示（2026-09-06「経営ダッシュボードと会計処理の体感速度改善」）に基づく。
-- 書き込みはkeiei-kd-refresh（service_role・op=pl_monthly / media_monthly / deposit_monthly）のみ。
--
-- 【湛盖範囲についての注記（v1・重要）】
-- ①kd_pl_monthly_summaryの広告費(ad)は、DB_PL手入力のA区分のみを集計している。ns-daily-import/
--   広告費DBシート由来の自動広告費（stg_ad_cost・BQミラー済み）は含まれていない——読み取り専用の
--   GASアクションが存在せず（bqSyncAdCostは書き込み専用）、レーンPはGASに触れないため新設できない。
--   担当A側でbqGetSpot/bqGetPLと同じ方針の読み取り専用アクション（例:bqGetAdCost）を追加してもらえれば
--   次のリフレッシュで自動的に反映できる設計にしてある（WORKLOGで依頼済み）。
-- ②簡易キャッシュフロー（法人税等・減価償却費・返済元金）はv1では計算していない（pl_item_breakdown
--   jsonbに勘定科目別の内訳を保持しているので、減価償却費はそこから拾える。返済元金はstg_loan_principal
--   が別データ源のため対象外）。
-- ③kd_media_monthly_summaryの広告費・ROAS・キャンセル率は①と同じ理由でv1では未対応（net_sales/
--   guests/partiesのみ）。
-- ④kd_deposit_monthly_summaryの「入金元別内訳」はstg_depositにmemo列しかなく構造化されたソース種別が
--   無いため、source_breakdown列だけ用意しjsonbは空のまま（将来、口座→種別の対応表ができ次第埋める）。

-- ---------------------------------------------------------------------
-- 0. kd_dashboard_daily_summaryへcost/labor列を追加（PL月次の自動売上/原価/人件費の元データ。
--    bqDailyStoreFull()が既に取得しているのに保存していなかった列。担当AのTK-60対応で発覚した
--    ギャップの1つ）
-- ---------------------------------------------------------------------
alter table public.kd_dashboard_daily_summary add column if not exists cost numeric;   -- cogs（原価・自動）
alter table public.kd_dashboard_daily_summary add column if not exists labor numeric;  -- labor_cost_total（人件費・自動。社員+PA。スポットは別途DB_PL L区分で手入力）
comment on column public.kd_dashboard_daily_summary.cost is '原価(F・自動)。fact_daily_store.cogs。DB_PLのF区分手入力分は含まない（kd_pl_monthly_summary.cost_manualが別途持つ）';
comment on column public.kd_dashboard_daily_summary.labor is '人件費(L・自動)。fact_daily_store.labor_cost_total。DB_PLのL区分手入力分（スポット等）は含まない';

-- ---------------------------------------------------------------------
-- 1. kd_pl_monthly_summary: store×年月のPL集計（app.jsのplAgg()/plCatOf()と同じF/L/A/R/O区分ルール）
-- ---------------------------------------------------------------------
create table if not exists public.kd_pl_monthly_summary (
  id uuid primary key default gen_random_uuid(),
  store_id uuid references public.stores (id),        -- NULL=全社共通経費（DB_PLの店舗名が空の行。設計書§3の共通ルール）
  corporation_id uuid references public.corporations (id),
  year_month text not null check (year_month ~ '^\d{4}-\d{2}$'),
  sales numeric,                -- 自動（kd_dashboard_daily_summary.net_salesの月合計。共通経費行はnull）
  cost_auto numeric,            -- 自動原価（kd_dashboard_daily_summary.costの月合計）
  cost_manual numeric,          -- DB_PL F区分の手入力合計
  cost_total numeric,           -- cost_auto+cost_manual
  labor_auto numeric,           -- 自動人件費（kd_dashboard_daily_summary.laborの月合計）
  labor_manual numeric,         -- DB_PL L区分の手入力合計（スポット人件費のPL反映分含む）
  labor_total numeric,          -- labor_auto+labor_manual
  ad_manual numeric,            -- DB_PL A区分の手入力合計（自動広告費は上記注記②により未対応）
  rent numeric,                 -- DB_PL R区分合計
  other numeric,                -- DB_PL O区分合計
  gross_profit numeric,         -- sales-cost_total（共通経費行はnull）
  sga numeric,                  -- labor_total+ad_manual+rent+other（販管費計）
  operating_profit numeric,     -- sales-cost_total-sga（共通経費行はnull。全社共通経費は個別店舗のopには含めない=plAggと同じ挙動）
  pl_item_breakdown jsonb not null default '{}'::jsonb, -- {"F":{"仕入":n,...},"L":{...},...}勘定科目別内訳（減価償却費等はここから拾う）
  source_updated_at timestamptz,
  computed_at timestamptz not null default now(),
  source_count int not null default 0,
  sync_run_id uuid references public.kd_sync_runs (id)
);
-- store_idのNULL（全社共通行）は年月ごとに1行だけに保ちたいので、NULLをセンチネル値に丸めてunique化
create unique index if not exists kd_pl_monthly_summary_unique
  on public.kd_pl_monthly_summary (coalesce(store_id, '00000000-0000-0000-0000-000000000000'::uuid), year_month);
create index if not exists kd_pl_monthly_summary_ym_idx on public.kd_pl_monthly_summary (year_month desc);
create index if not exists kd_pl_monthly_summary_corp_ym_idx on public.kd_pl_monthly_summary (corporation_id, year_month);

alter table public.kd_pl_monthly_summary enable row level security;
drop policy if exists kd_pl_monthly_summary_select on public.kd_pl_monthly_summary;
create policy kd_pl_monthly_summary_select on public.kd_pl_monthly_summary
  for select to authenticated using (
    exists (
      select 1 from public.users u
      where u.id = auth.uid() and u.is_active and (
        u.is_master or u.role in ('CEO', 'HQ', 'TEAM')
        or (u.role = 'TENCHO' and store_id is not null and exists (
              select 1 from public.user_stores us where us.user_id = u.id and us.store_id = kd_pl_monthly_summary.store_id
            ))
      )
    )
  );

-- ---------------------------------------------------------------------
-- 2. kd_media_monthly_summary: store×年月×媒体（正規名）の売上分析集計
-- ---------------------------------------------------------------------
create table if not exists public.kd_media_monthly_summary (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id),
  corporation_id uuid references public.corporations (id),
  year_month text not null check (year_month ~ '^\d{4}-\d{2}$'),
  media_name text not null,     -- tpl_media_aliasの正規名（未登録表記はkd_unresolved_names(kind='media')へ隔離）
  net_sales numeric,
  guests int,
  parties int,
  source_updated_at timestamptz,
  computed_at timestamptz not null default now(),
  source_count int not null default 0,
  sync_run_id uuid references public.kd_sync_runs (id)
);
create unique index if not exists kd_media_monthly_summary_unique
  on public.kd_media_monthly_summary (store_id, year_month, media_name);
create index if not exists kd_media_monthly_summary_ym_idx on public.kd_media_monthly_summary (year_month desc);
create index if not exists kd_media_monthly_summary_corp_ym_idx on public.kd_media_monthly_summary (corporation_id, year_month);

alter table public.kd_media_monthly_summary enable row level security;
drop policy if exists kd_media_monthly_summary_select on public.kd_media_monthly_summary;
create policy kd_media_monthly_summary_select on public.kd_media_monthly_summary
  for select to authenticated using (
    exists (
      select 1 from public.users u
      where u.id = auth.uid() and u.is_active and (
        u.is_master or u.role in ('CEO', 'HQ', 'TEAM')
        or (u.role = 'TENCHO' and exists (
              select 1 from public.user_stores us where us.user_id = u.id and us.store_id = kd_media_monthly_summary.store_id
            ))
      )
    )
  );

-- ---------------------------------------------------------------------
-- 3. kd_deposit_monthly_summary: store×年月の入金集計＋売上との突合
-- ---------------------------------------------------------------------
create table if not exists public.kd_deposit_monthly_summary (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id),
  corporation_id uuid references public.corporations (id),
  year_month text not null check (year_month ~ '^\d{4}-\d{2}$'),
  deposit_total numeric,
  deposit_count int,
  sales_total numeric,          -- 突合用（kd_dashboard_daily_summary.net_salesの月合計。参考値）
  diff numeric,                 -- deposit_total-sales_total（入金は決済手数料等で完全一致しないのが通常。大きく外れた月の目印用）
  source_breakdown jsonb not null default '{}'::jsonb, -- 入金元別内訳（未実装・注記④参照）
  source_updated_at timestamptz,
  computed_at timestamptz not null default now(),
  source_count int not null default 0,
  sync_run_id uuid references public.kd_sync_runs (id)
);
create unique index if not exists kd_deposit_monthly_summary_unique
  on public.kd_deposit_monthly_summary (store_id, year_month);
create index if not exists kd_deposit_monthly_summary_ym_idx on public.kd_deposit_monthly_summary (year_month desc);
create index if not exists kd_deposit_monthly_summary_corp_ym_idx on public.kd_deposit_monthly_summary (corporation_id, year_month);

alter table public.kd_deposit_monthly_summary enable row level security;
drop policy if exists kd_deposit_monthly_summary_select on public.kd_deposit_monthly_summary;
create policy kd_deposit_monthly_summary_select on public.kd_deposit_monthly_summary
  for select to authenticated using (
    exists (
      select 1 from public.users u
      where u.id = auth.uid() and u.is_active and (
        u.is_master or u.role in ('CEO', 'HQ', 'TEAM')
        or (u.role = 'TENCHO' and exists (
              select 1 from public.user_stores us where us.user_id = u.id and us.store_id = kd_deposit_monthly_summary.store_id
            ))
      )
    )
  );
