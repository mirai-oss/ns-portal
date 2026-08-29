-- ============================================================
-- シフト仕上げ B-1（旧要望B+C）: 遅刻・早退・欠勤の自動判定＋修正申請フロー — 担当B
-- 実装指示書_担当B_シフト仕上げと機能追加_2026-08-29.md B-1 参照。
-- 自動判定はsf_shifts（公開済み予定）×labor_cost_daily（担当D管轄・読み取りのみ）を
-- クライアント側で突き合わせるだけなのでSQL変更不要。ここでは「修正申請」の受付テーブルのみ追加。
-- 実行場所: Supabase SQL Editor / Management API（何度実行しても壊れません）
-- ============================================================

-- 従業員が「打刻がおかしい」と申請する窓口。実際のスマレジ側打刻データの書き換えは対象外
-- （timecard.attendances:write スコープ未申請のため）。承認後は店長・本部が手動でスマレジ側を直す運用。
create table if not exists sf_attendance_correction_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  store_id uuid not null references stores(id) on delete cascade,
  work_date date not null,
  kind text not null check (kind in ('late','early_leave','absence','other')), -- 遅刻/早退/欠勤/その他
  reason text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references users(id) on delete set null,
  resolved_note text
);
create index if not exists sf_attendance_correction_store_idx on sf_attendance_correction_requests (store_id, work_date);
create index if not exists sf_attendance_correction_user_idx on sf_attendance_correction_requests (user_id);

alter table sf_attendance_correction_requests enable row level security;

-- 閲覧: 本人 or 管理者（既存sf_can_manageを流用）
drop policy if exists sfacr_read on sf_attendance_correction_requests;
create policy sfacr_read on sf_attendance_correction_requests for select using (
  auth.uid() is not null and (user_id = auth.uid() or sf_can_manage(store_id))
);
-- 作成: 本人のみ
drop policy if exists sfacr_insert on sf_attendance_correction_requests;
create policy sfacr_insert on sf_attendance_correction_requests for insert with check (user_id = auth.uid());
-- 更新（承認・却下）: 管理者のみ
drop policy if exists sfacr_update on sf_attendance_correction_requests;
create policy sfacr_update on sf_attendance_correction_requests for update using (
  sf_can_manage(store_id)
) with check (
  sf_can_manage(store_id)
);
