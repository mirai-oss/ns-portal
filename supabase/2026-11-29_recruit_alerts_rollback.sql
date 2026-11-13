-- 2026-11-29_recruit_alerts.sql を外す  ★実行は別途承認
--   ふだん「止める」ときは、これではなく  select recruit_alerts_set(false);  （知らせのスイッチを切るだけ。何も消えない）
--   先に、Edge Function（recruit-action・slack-interact）を、この SQL の関数を呼ばない版に戻すこと。既存の見回り（recruit_notice_sweep・pending-reminders）には触れない。

-- 1) 定期実行を止める
do $$
begin
  if exists (select 1 from cron.job where jobname = 'recruit-unhandled-alert') then perform cron.unschedule('recruit-unhandled-alert'); end if;
end $$;

-- 2) 足した関数を消す
drop function if exists public.recruit_calendar_retry_save(uuid, text, text);
drop function if exists public.recruit_calendar_retry_begin(uuid, text, uuid, text, boolean);
drop function if exists public.recruit_send_retry_begin(uuid, text, uuid, text);
drop function if exists public.recruit_send_retry_info(uuid, uuid);
drop function if exists public.recruit_alerts_trigger();
drop function if exists public.recruit_alerts_set(boolean);
drop function if exists public.recruit_alerts_on();

-- 3) 設定のキーを外す
update app_settings set value = value - 'alerts_enabled' where key = 'recruit_actions' and value ? 'alerts_enabled';

-- 4) recruit_send_finish を、第 2 弾（2026-11-27_recruit_outbox.sql）の中身に戻す
create or replace function public.recruit_send_finish(p_outbox uuid, p_status text, p_error text default null, p_response jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_row applicant_outbox%rowtype; v_msg uuid; v_op uuid;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_status is null or p_status not in ('sent', 'failed', 'unknown') then raise exception 'p_status が正しくありません'; end if;
  select * into v_row from applicant_outbox where id = p_outbox for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '送信箱の行が見つかりません'); end if;
  if v_row.status <> 'sending' then
    -- すでに結果が入っている（二度目の呼び出し）: 何も変えない
    return jsonb_build_object('ok', v_row.status = p_status, 'code', 'already', 'status', v_row.status, 'outbox_id', v_row.id);
  end if;
  if p_status = 'sent' then
    insert into applicant_messages (applicant_id, channel, direction, body, sent_at, source_ref, direction_fixed, sent_by)
    values (v_row.applicant_id, 'line', 'out', left(v_row.body, 8000), now(), 'outbox:' || v_row.id::text, true, v_row.actor_id)
    on conflict (source_ref) do nothing
    returning id into v_msg;
    update applicants set updated_at = now(),
           last_actor_id = coalesce(v_row.actor_id, last_actor_id),
           last_actor_at = case when v_row.actor_id is not null then now() else last_actor_at end,
           interview_sent_at = case when v_row.purpose = 'interview_notice' then now() else interview_sent_at end   -- 面接の案内を送った印（画面の mark_interview_sent と同じ）
     where id = v_row.applicant_id;
    update applicant_outbox set status = 'sent', sent_at = now(), message_id = v_msg, response = p_response, error = null, updated_at = now() where id = p_outbox;
    v_op := recruit_op_log(v_row.applicant_id, 'message_send', v_row.actor_id, v_row.via, 'send:' || v_row.id::text || ':sent', '{}'::jsonb,
                           jsonb_build_object('outbox_id', v_row.id, 'purpose', v_row.purpose, 'mode', 'live', 'message_id', v_msg, 'chars', length(v_row.body)), 'done', null, null);
  else
    update applicant_outbox set status = p_status, error = left(coalesce(p_error, ''), 500), response = p_response, updated_at = now() where id = p_outbox;
    v_op := recruit_op_log(v_row.applicant_id, 'message_send', v_row.actor_id, v_row.via, 'send:' || v_row.id::text || ':' || p_status, '{}'::jsonb,
                           jsonb_build_object('outbox_id', v_row.id, 'purpose', v_row.purpose, 'mode', 'live', 'status', p_status), 'failed',
                           left(case when p_status = 'unknown' then '結果不明: ' else '' end || coalesce(p_error, ''), 500), null);
  end if;
  return jsonb_build_object('ok', true, 'code', p_status, 'status', p_status, 'outbox_id', v_row.id, 'message_id', v_msg);
end $$;
