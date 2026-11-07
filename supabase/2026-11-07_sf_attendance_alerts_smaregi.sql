-- =============================================================
-- 勤怠確認ボタン②: 承認後にスマレジ・タイムカードの勤務実績へ書き戻す（2026-11-07・ユーザー指示）
-- 状態: ★ 未適用 ★（dry-run 済み）
-- 事実: スマレジ「勤怠更新 PUT /{contract}/timecard/shifts/{shift_result_id}」に division=result で出勤・退勤を送れる。
--       必要スコープは timecard.shifts:write（シフト同期で取得済み。新しい申請は不要）。締め済み期間は 409。
-- 流れ: マスター承認 → RPC sf_attendance_fix_decide（ハブ反映・手修正ロック）→ slack-interact が EF smaregi-attendance-fix を呼ぶ
--       → PUT 成功なら smaregi_sync_status=synced・ハブの手修正ロックを解除（以後はスマレジが正・翌朝の同期で同じ値になる）
--       → 失敗なら failed＋理由を Slack に表示（手で直す）。
-- =============================================================
alter table sf_attendance_alerts
  add column if not exists smaregi_sync_status text check (smaregi_sync_status in ('pending','synced','failed','skipped')),
  add column if not exists smaregi_synced_at   timestamptz,
  add column if not exists smaregi_error       text,
  add column if not exists smaregi_response    jsonb;
comment on column sf_attendance_alerts.smaregi_sync_status is '承認後のスマレジ書き戻し: pending=未実施 synced=成功 failed=失敗（手で直す） skipped=実績IDなし等';

-- 承認 RPC は無変更。承認時に pending を立てるのは EF 側（slack-interact → smaregi-attendance-fix）。
-- 確認用: select id, status, smaregi_sync_status, smaregi_error from sf_attendance_alerts where status='approved' order by decided_at desc;
