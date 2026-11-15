-- =============================================================
-- 戻し用: 2026-12-10_attendance_request_two_stage.sql（勤怠修正申請の第 2 弾）を取り消す
--   手順: ①スイッチ two_stage を false にする ②Edge Function を第 1 弾の版に戻す ③2 段階の承認待ち（flow='two_stage'・status='pending'）が 0 件なのを確かめる ④この SQL
--   ★ 2 段階の承認待ちが残っているときは流さないこと（下の確認が例外で止める）。残っている申請は、先に 承認・却下・取り下げ で終わらせる。
--   消える物: 一次承認者の設定と変更の履歴・足した列（flow / stage / first_* / returned_* / round ほか）・足した関数とトリガー。
--   消えない物: 申請そのもの・第 1 弾の履歴の表（sf_attendance_request_events）・勤怠のデータ・Slack の投稿。
-- =============================================================
do $$
declare v_n int;
begin
  select count(*) into v_n from sf_attendance_requests where flow = 'two_stage' and status = 'pending';
  if v_n > 0 then raise exception '2 段階承認の承認待ちが % 件あります。先に終わらせてから戻してください', v_n; end if;
end $$;
update app_settings set value = value || '{"two_stage": false}'::jsonb where key = 'attendance_request_flow';
drop trigger if exists sf_attendance_requests_flow_guard_bu on sf_attendance_requests;
drop trigger if exists sf_attendance_requests_flow_ai on sf_attendance_requests;
drop trigger if exists sf_attendance_requests_b_flow_bi on sf_attendance_requests;
drop function if exists public.sf_attendance_request_detail(uuid, uuid);
drop function if exists public.sf_attendance_first_approver_set(uuid, uuid, uuid, text);
drop function if exists public.sf_attendance_request_sync_claim(uuid, uuid);
drop function if exists public.sf_attendance_request_message(uuid, uuid, text, text);
drop function if exists public.sf_attendance_request_resubmit(uuid, uuid, timestamptz, timestamptz, text, timestamptz, timestamptz, timestamptz, timestamptz, text);
drop function if exists public.sf_attendance_request_act(uuid, uuid, text, text, text);
drop function if exists public.sf_attendance_times_check(date, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz);
drop function if exists public.sf_attendance_requests_flow_guard();
drop function if exists public.sf_attendance_requests_flow_routed();
drop function if exists public.sf_attendance_requests_flow_init();
drop function if exists public.sf_attendance_request_route(uuid, uuid, uuid);
drop function if exists public.sf_attendance_request_state(sf_attendance_requests);
alter table sf_attendance_requests
  drop column if exists flow, drop column if exists stage, drop column if exists first_approver_id, drop column if exists first_skipped,
  drop column if exists first_decided_by, drop column if exists first_decided_at, drop column if exists first_note, drop column if exists final_requested_at,
  drop column if exists returned_by, drop column if exists returned_at, drop column if exists return_note, drop column if exists round, drop column if exists sync_claimed_at;
drop table if exists sf_attendance_first_approver_changes;
drop table if exists sf_attendance_first_approvers;
