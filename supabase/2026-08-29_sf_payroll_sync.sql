-- 2026-08-29 担当B（nippo）
-- スマレジ給与明細API（GET /budgets/monthly/0/{staffId}?year=&month=、store_id=0=全店舗合算）から
-- 月次の確定給与を定期的に取得して保存するためのテーブル。
-- 参照: WORKLOG.md 2026-08-22「給与明細API発見・月次突合で完全一致を確認」
--       supabase/functions/smaregi-payroll-reconcile/index.ts（既存・今回は無変更）
--
-- 位置づけ: これまでこのAPIの値は smaregi-payroll-reconcile が毎回スマレジへ問い合わせて
--   使い捨てていた（保存先が無かった）。このテーブルに保存することで、
--   ①nippoのシフト調整画面の人件費見積もり ②将来的に経営ダッシュボードの
--   社員人件費（現在はスプレッドシート手入力）の置き換え検討、の両方から再利用できるようにする。
-- 所有: nippo（担当B）が新規作成・書き込みは新設Edge Functionのみ。読み取りは他システムも可。
create table if not exists sf_payroll_sync (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  year_month text not null, -- 'YYYY-MM'（store_id=0=全店舗合算のため店舗の概念を持たない）
  regular_wage numeric,             -- allowanceWage.regularWage（確定賃金。深夜割増・残業・控除まで反映済みとAPI側で確認済み）
  working_day_count integer,        -- shiftTime.workingDayCount
  total_working_minutes integer,    -- shiftTime.totalWorkingTime
  raw jsonb,                        -- API生レスポンス全体（将来items追加時のためのセーフティネット）
  synced_at timestamptz not null default now(),
  unique (user_id, year_month)
);
comment on table sf_payroll_sync is 'スマレジ給与明細API(budgets/monthly)から月次の確定給与を定期同期したもの。2026-08-29追加。店舗別振り分けはsf_payroll_allocations（マスターの手動入力）で別途行う';

alter table sf_payroll_sync enable row level security;

-- 読み取り: CEO/HQ/マスター、または本人
create policy sf_payroll_sync_read on sf_payroll_sync for select using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ') or u.id = sf_payroll_sync.user_id))
);
-- 書き込みはservice_role（Edge Function）のみを想定。クライアントからの直接書き込みは許可しない（ポリシー無し=拒否）

-- 2026-08-29 マスターが店舗・期間ごとに手動入力する台帳（基本給の按分・交通費・インセンティブ・賞与予定）
create table if not exists sf_payroll_allocations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  store_id uuid not null references stores(id),
  period_key text not null, -- sf_shifts等と同じ形式 'YYYY-MM-A'|'YYYY-MM-B'（半月単位）
  kind text not null check (kind in ('base','commute','incentive','bonus')),
  amount numeric not null,
  note text,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table sf_payroll_allocations is 'マスターが手動で入力する、社員の店舗別・期間別の人件費内訳（基本給按分/交通費/インセンティブ/賞与予定）。2026-08-29追加';

alter table sf_payroll_allocations enable row level security;

create policy sf_payroll_allocations_read on sf_payroll_allocations for select using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ') or u.id = sf_payroll_allocations.user_id))
);
-- 書き込みはマスターのみ（ユーザー要望「マスターの人が振り分けられるように」）
create policy sf_payroll_allocations_write on sf_payroll_allocations for all using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.is_master)
) with check (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.is_master)
);
