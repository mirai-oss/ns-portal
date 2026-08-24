-- D-2: 社員固定給の勤務日ベース按分（比較レポート用）
-- docs/実装指示書_担当D_勤怠給与監視_2026-08-24.md D-2
--
-- 前提（2026-08-24調査で確定）:
--   ・「社員人件費DB」シート（現行の手入力の正）は店舗×月の合計額のみで、従業員別の内訳を持たない。
--     そのため按分は「店舗単位の再配分」で行う（ユーザー確認済み・2026-08-24）:
--     店舗の月合計（現行値・BigQuery fact_daily_store経由で取得）を、その店舗のSHAIN/TENCHO
--     （users.role）の日別労働時間の合計比率で日別に再配分する。月合計は常に現行と一致する
--     （日別の形が変わるだけ）。掛け持ち0名の現状ではほぼ従業員単位の計算と一致する見込み。
--   ・月内の対象店舗でSHAIN/TENCHOの勤務実績が1件も無い場合は暦日割りにフォールバック
--     （現行の「社員人件費DB」年月のみ入力時の挙動と同じ）。
--
-- このファイルはPostgres側の「重み（その店舗・その日にSHAIN/TENCHOが働いた分数の合計）」のみを提供する。
-- 現行の月合計額そのものはBigQuery（tori-dashboardのGAS経由）から取得するため、
-- Edge Function側（labor-allocation-compare）で組み合わせる。

create or replace view labor_salary_daily_weight as
select
  l.store_id,
  s.name as store_name,
  l.work_date,
  date_trunc('month', l.work_date)::date as ym,
  sum(l.worked_minutes) as daily_minutes
from labor_cost_daily l
join users u on u.id = l.user_id
join stores s on s.id = l.store_id
where u.role in ('SHAIN', 'TENCHO') and u.is_active
group by l.store_id, s.name, l.work_date, date_trunc('month', l.work_date)::date;

-- 比較レポートの結果（店舗×日）。週次workflowが上書き保存する（同じ(ym,store_name,work_date)は上書き）。
create table if not exists labor_allocation_compare_report (
  id uuid primary key default gen_random_uuid(),
  ym date not null,                     -- 対象年月（月初日）
  store_id uuid references stores(id),  -- 店舗名がstoresと対応付かない場合はnull（store_nameで判別）
  store_name text not null,             -- BigQuery(fact_daily_store)側の店舗名
  work_date date not null,
  legacy_salary_bonus numeric,          -- 現行（暦日割り）: 社員給与賞与
  legacy_welfare numeric,               -- 現行: 法定福利費
  legacy_commute numeric,               -- 現行: 交通費
  new_salary_bonus numeric,             -- 新方式（勤務日ベース）: 社員給与賞与
  new_welfare numeric,
  new_commute numeric,
  weight_basis text not null check (weight_basis in ('worked_minutes', 'calendar_fallback')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists labor_allocation_compare_report_ym_idx on labor_allocation_compare_report(ym);
create unique index if not exists labor_allocation_compare_report_uniq
  on labor_allocation_compare_report(ym, store_name, work_date);
