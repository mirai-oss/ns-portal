-- 2026-08-30 担当B（nippo）続き
-- ユーザー要望: 従業員管理でスマレジのスタッフIDを新しく登録した人がいたら、
-- その人の過去の勤怠実績（labor_cost_daily）を自動でまとめて取得し直したい。
-- このテーブルは「もうバックフィル済みの人」を記録しておき、まだ記録に無い人＝
-- 新しく登録された人、を毎日の自動ジョブが見つけられるようにするためのもの。
create table if not exists sf_attendance_backfill_done (
  user_id uuid primary key references users(id) on delete cascade,
  smaregi_staff_id text,
  backfilled_at timestamptz not null default now()
);
comment on table sf_attendance_backfill_done is 'スマレジ勤怠実績(labor_cost_daily)の過去分バックフィルが済んだ人の記録。2026-08-30追加。書込みはservice_roleのみ想定';

alter table sf_attendance_backfill_done enable row level security;
create policy sf_attendance_backfill_done_read on sf_attendance_backfill_done for select using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.is_master)
  or has_feature(auth.uid(), 'labor_cost_view')
);
