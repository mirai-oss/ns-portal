-- =====================================================================
-- 勤怠実績・日次人件費（labor_cost_daily）新設 — データ基盤Day2 タスクB
-- =====================================================================
-- 背景: 現在の人件費は「CSV手動ダウンロード→シート貼り付け→成形」で運用されている。
--   スマレジ・タイムカードAPI（GET /timecard/shifts/staffs/{staffId}/daily?division=result）
--   で打刻実績が取得できることを確認済み（2026-08-21 使い捨てEdge Functionで検証）。
--   このAPIには概算人件費(personnelExpenses)が付くが、深夜割増・交通費の扱いが
--   仕様書に明記されておらず過去に計算誤りが公式に認められた経緯がある
--   （データ基盤監査レポート§12）ため、正確な額は自前計算が必要。
--
-- 方針: 旧経路（CSV→シート）は止めない。追加のみ。
--   ・attendance_records（既存テーブル。生の打刻ログ）に実績を保存
--   ・labor_cost_daily（新設。日次の集計・人件費見積もり）に保存
--   ・従業員の特定は employee_profiles.smaregi_staff_id をキーにする
--     （「スマレジが従業員情報の正本」という2026-08-21のユーザー方針決定に基づく。
--      public.users.smaregi_staff_id という同名の別列があるが未使用＝混同しないこと）
-- 実行場所: Supabase SQL Editor / Management API（何度実行しても壊れません）
-- =====================================================================

create table if not exists labor_cost_daily (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id),
  store_id uuid references stores(id),
  work_date date not null,
  clock_in timestamptz,
  clock_out timestamptz,
  worked_minutes numeric,
  tardy boolean not null default false,       -- スマレジのtardyFlag
  early_leaving boolean not null default false, -- スマレジのearlyLeavingFlag
  smaregi_estimate_cost numeric,              -- スマレジAPIのpersonnelExpenses（概算・参考値）
  computed_cost numeric,                      -- 自前計算した人件費（未実装分はnull。時給×時間+深夜割増+交通費）
  smaregi_shift_result_id text,               -- スマレジ側の実績ID（突合・重複防止キー）
  smaregi_staff_id text,                      -- 参考保持（employee_profiles.smaregi_staff_idと一致するはず）
  source text not null default 'smaregi',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (smaregi_shift_result_id)
);
alter table labor_cost_daily enable row level security;
drop policy if exists labor_cost_daily_read on labor_cost_daily;
create policy labor_cost_daily_read on labor_cost_daily for select using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active
    and (u.role in ('CEO','HQ','TEAM') or u.is_master))
);
-- 書き込みはservice_role（Edge Function）のみ想定のためRLSのwriteポリシーは設けない（誰も直接書けない）

create index if not exists labor_cost_daily_work_date_idx on labor_cost_daily(work_date);
create index if not exists labor_cost_daily_user_idx on labor_cost_daily(user_id, work_date);

-- attendance_records（既存テーブル）に、突合・重複防止用の一意キーを追加
-- ※ PostgRESTのupsert(onConflict)は部分インデックス(where句付き)にマッチできないため、
--   通常のunique indexにしている（NULL同士は標準SQLの仕様上、常に別物として扱われるため
--   複数nullが共存しても問題ない）
alter table attendance_records add column if not exists smaregi_shift_result_id text;
create unique index if not exists attendance_records_smaregi_result_idx
  on attendance_records(smaregi_shift_result_id);
