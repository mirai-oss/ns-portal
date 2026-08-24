-- ============================================================
-- シフトv5 UI B-2: ③確定シフト（未確認者・再通知・変更申請）— 担当B
-- 実装指示書_担当B_シフトUIv5_2026-08-24.md B-2 参照。
-- sf_shiftsへの列追加＋新テーブルは追記のみ。既存SQLファイル(2026-08-19_shifts.sql等)は無編集。
-- 実行場所: Supabase SQL Editor / Management API（何度実行しても壊れません）
-- ============================================================

-- 公開後、本人が確認済みかどうか（未確認者一覧・再通知に使う）
alter table sf_shifts add column if not exists confirmed_at timestamptz;

-- 本人による確認専用RPC。
-- 既存のsfs_update RLS（公開後は本人は更新不可・管理者のみ）はそのまま維持したいので、
-- confirmed_atだけをsecurity definerで安全に更新できる狭い入口として新設する
-- （sf_reminder_targets/sf_mark_reminded と同じ考え方＝2026-08-20_shift_reminders_functions.sql参照）
create or replace function sf_confirm_shifts(p_period_key text) returns void
language sql security definer set search_path = public as $$
  update sf_shifts set confirmed_at = now()
  where user_id = auth.uid() and period_key = p_period_key and status = 'published' and confirmed_at is null;
$$;

-- 変更申請（公開後の交代・修正希望の「受付」のみ。反映自体は既存の代理編集＋再公開フローを店長・本部が使う）
create table if not exists sf_change_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  store_id uuid not null references stores(id) on delete cascade,
  work_date date not null,
  period_key text not null,
  reason text,
  status text not null default 'pending' check (status in ('pending','resolved','dismissed')),
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references users(id) on delete set null,
  resolved_note text
);
create index if not exists sf_change_requests_store_idx on sf_change_requests (store_id, period_key);
create index if not exists sf_change_requests_user_idx on sf_change_requests (user_id);

alter table sf_change_requests enable row level security;

-- 閲覧: 本人 or 管理者
drop policy if exists sfcr_read on sf_change_requests;
create policy sfcr_read on sf_change_requests for select using (
  auth.uid() is not null and (user_id = auth.uid() or sf_can_manage(store_id))
);
-- 作成: 本人のみ（自分の申請しか作れない）
drop policy if exists sfcr_insert on sf_change_requests;
create policy sfcr_insert on sf_change_requests for insert with check (user_id = auth.uid());
-- 更新（解決・却下）: 管理者のみ
drop policy if exists sfcr_update on sf_change_requests;
create policy sfcr_update on sf_change_requests for update using (
  sf_can_manage(store_id)
) with check (
  sf_can_manage(store_id)
);
