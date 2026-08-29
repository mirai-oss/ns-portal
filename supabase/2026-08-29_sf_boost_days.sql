-- ============================================================
-- シフト仕上げ B-3（旧要望F）: 出勤強化日 U11（要件定義書.md §27.5） — 担当B
-- 実装指示書_担当B_シフト仕上げと機能追加_2026-08-29.md B-3 参照。
-- 評価連携（該当日に出た人を評価⑪へ反映）・スマレジwage_apply連携（時給自動アップ）は
-- 今回は対象外（表示のみ）。既存テーブル無編集・新規テーブルの追加のみ。
-- 実行場所: Supabase SQL Editor / Management API（何度実行しても壊れません）
-- ============================================================

create table if not exists sf_boost_days (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references stores(id) on delete cascade,
  work_date date not null,
  message text,                                             -- 店長からのひと言（例: 「土曜ディナーが繁忙予想。出られる人募集！」）
  incentive_type text not null default 'none' check (incentive_type in ('hourly','shift','none')), -- 時給+○円 / 1勤務+○円 / インセンティブなし
  incentive_amount numeric,
  created_by uuid references users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (store_id, work_date)
);
create index if not exists sf_boost_days_date_idx on sf_boost_days (work_date);

alter table sf_boost_days enable row level security;

-- 閲覧: ログイン済みなら誰でも（自分の店舗以外の強化日を見ても実害が無く、
--   ヘルプ希望の人が「他店舗が強化日だから行こうか」と判断する材料にもなる）
drop policy if exists sfbd_read on sf_boost_days;
create policy sfbd_read on sf_boost_days for select using (auth.uid() is not null);

-- 作成・更新・削除: その店舗の管理者のみ（既存sf_can_manageを流用）
drop policy if exists sfbd_write on sf_boost_days;
create policy sfbd_write on sf_boost_days for all using (
  sf_can_manage(store_id)
) with check (
  sf_can_manage(store_id)
);
