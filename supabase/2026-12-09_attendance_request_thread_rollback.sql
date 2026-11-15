-- =============================================================
-- 戻し用: 2026-12-09_attendance_request_thread.sql（勤怠修正申請の第 1 弾）を取り消す
--   先に Edge Function を元に戻す（または スイッチ thread を false にする）こと。
--   第 2 弾（2026-12-10_attendance_request_two_stage.sql）を入れているときは、先に第 2 弾の戻し用を流すこと。
--   消える物: 履歴の表（中の履歴も消える）・足した列（before_meta ほか）・親とスレッドの場所の控え（notice_cases の attendance_request）。
--   消えない物: 申請そのもの（sf_attendance_requests の今までの列）・勤怠のデータ・Slack に出た投稿。
-- =============================================================
drop trigger if exists sf_attendance_requests_event_aiu on sf_attendance_requests;
drop trigger if exists sf_attendance_requests_a_snapshot_bi on sf_attendance_requests;
drop function if exists public.sf_attendance_request_view(uuid);
drop function if exists public.sf_attendance_request_source_check(uuid);
drop function if exists public.sf_attendance_requests_event_log();
drop function if exists public.sf_attendance_requests_snapshot();
drop table if exists sf_attendance_request_events;
drop function if exists public.sf_attendance_request_events_guard();
alter table sf_attendance_requests
  drop column if exists before_meta,
  drop column if exists source_changed_at,
  drop column if exists source_change;
delete from notice_cases where type_key = 'attendance_request';
delete from notice_types where type_key = 'attendance_request';
delete from app_settings where key = 'attendance_request_flow';
