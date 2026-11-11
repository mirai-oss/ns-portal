-- 2026-11-13_break_autofill.sql を外す  ★実行は別途承認
--   先に: 設定 attendance_break_autofill.enabled を false に戻し、Edge Function の定期実行を止めること。
--   補完の履歴と例外の申告は消える（先に控えを取ること）。スマレジと管理システムの勤怠に入った休憩は、そのまま残る（消さない）。
do $$
begin
  if coalesce((select (value ->> 'enabled')::boolean from app_settings where key = 'attendance_break_autofill'), false) then raise exception '設定 attendance_break_autofill.enabled が true です。先に false に戻してください'; end if;
end $$;
drop function if exists hr_break_autofill_status(integer);
drop function if exists attendance_break_autofill_task_sync();
drop function if exists sf_break_exception_submit(uuid, date, text, integer, text, uuid);
drop function if exists attendance_break_source(uuid);
drop function if exists attendance_break_autofill_reconcile();
drop function if exists attendance_break_autofill_finish(uuid, text, text, jsonb, numeric, numeric);
drop function if exists attendance_break_autofill_begin(uuid, timestamptz, timestamptz, jsonb, text, text);
drop function if exists attendance_break_autofill_scan(date, date, uuid);
drop function if exists attendance_break_autofill_cfg();
drop table if exists attendance_break_exceptions;
drop table if exists attendance_break_autofills;
delete from app_settings where key = 'attendance_break_autofill';
