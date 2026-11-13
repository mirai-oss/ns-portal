-- 採用管理: 知らせ（24 時間の未対応 → 予備の担当へ／LINE の送信失敗・結果不明とカレンダー登録の失敗 →［もう一度］）（2026-11-29 下書き）
--   設計: docs/設計書_採用_面接確定とLINEのSlack操作_2026-11-13.md §4 の C5 ／ この段階のメモ: scratchpad ob18/stage3/メモ_第3弾.md
--   ★ 本番未適用（下書き。適用は別途承認）。戻し方: 2026-11-29_recruit_alerts_rollback.sql
--   前提: 2026-11-26_recruit_action_base.sql・2026-11-27_recruit_outbox.sql・2026-11-28_recruit_interview.sql が入っていること
--
--   これを適用しただけでは、何も送られない・何も変わらない。
--     ・24 時間の未対応の知らせ: 定期実行（毎時）を登録するが、「知らせのスイッチ recruit_actions.alerts_enabled（既定 false）」と
--       「予備の担当の設定 recruit_assign.part_backup（既定 null）」の両方がそろうまで、定期実行は Edge Function を呼ばずに戻る。
--       知らせるだけで、担当者（applicants.assignee_id）は変えない。
--     ・［もう一度］: 人がボタンを押し、確かめの窓で確かめてから、のときだけ動く。送信のスイッチ・試しモードの決まりは、第 2 弾のまま。
--   定期実行は、新しく 1 つ足す（既存の見回り recruit_notice_sweep と pending-reminders は、どちらも変えない）。
--   足すもの: 設定のキー 1 つ・関数 6 本・定期実行 1 つ。 変えるもの: recruit_send_finish（第 2 弾の関数）の「記録の鍵」に、やり直しの回数を足す（中身は同じ）。

-- ============ 0. 前提の確認 ============
do $$
begin
  if to_regclass('public.applicant_outbox') is null or to_regprocedure('public.recruit_unhandled_targets(timestamptz,boolean)') is null
     or to_regprocedure('public.recruit_interview_finish(uuid,text,text)') is null or to_regprocedure('public.recruit_send_finish(uuid,text,text,jsonb)') is null then
    raise exception '先に、第 1 弾（2026-11-26）と第 2 弾（2026-11-27・2026-11-28）の SQL を適用してください';
  end if;
end $$;

-- ============ 1. 知らせのスイッチ（既定 false） ============
update app_settings set value = value || '{"alerts_enabled": false}'::jsonb where key = 'recruit_actions' and not (value ? 'alerts_enabled');

-- いま、24 時間の未対応を知らせてよいか（スイッチが true、かつ、予備の担当が決まっている）
create or replace function public.recruit_alerts_on()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select value -> 'alerts_enabled' = 'true'::jsonb from app_settings where key = 'recruit_actions'), false)
         and recruit_assign_user('part_backup') is not null
$$;

-- スイッチの切り替え（マスターのみ）
create or replace function public.recruit_alerts_set(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not (onboarding_is_service() or coalesce((select is_master from users where id = auth.uid() and is_active), false)) then
    raise exception '権限がありません（マスターのみ）';
  end if;
  update app_settings set value = value || jsonb_build_object('alerts_enabled', coalesce(p_enabled, false)) where key = 'recruit_actions';
  return jsonb_build_object('alerts_enabled', coalesce(p_enabled, false), 'on', recruit_alerts_on());
end $$;

-- 定期実行が呼ぶ: スイッチと設定がそろっているときだけ、Edge Function recruit-action（op=alerts_scan）に「見てください」と知らせる（氏名・本文は送らない）
create or replace function public.recruit_alerts_trigger()
returns boolean language plpgsql security definer set search_path = public, net, extensions as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/recruit-action';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';   -- 公開用の鍵（recruit_notice_fire と同じ値。秘密ではない）
  v_secret text;
begin
  if recruit_alerts_on() is not true then return false; end if;
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then
    raise warning 'recruit_alerts_trigger: app_secrets.notify_slack_secret が未設定';
    return false;
  end if;
  perform net.http_post(
    url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'alerts_scan'),
    timeout_milliseconds := 60000);
  return true;
end $$;

-- ============ 2. LINE の送り直し（失敗・結果不明の行を、人が確かめてから、同じ行・同じ再送の鍵で、もう一度） ============
-- 記録の鍵に、やり直しの回数を足す（同じ行が 2 回目も失敗したとき、記録の鍵が重ならないように）。それ以外は、第 2 弾の recruit_send_finish と同じ
create or replace function public.recruit_send_finish(p_outbox uuid, p_status text, p_error text default null, p_response jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_row applicant_outbox%rowtype; v_msg uuid; v_op uuid; v_n text;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_status is null or p_status not in ('sent', 'failed', 'unknown') then raise exception 'p_status が正しくありません'; end if;
  select * into v_row from applicant_outbox where id = p_outbox for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '送信箱の行が見つかりません'); end if;
  if v_row.status <> 'sending' then
    return jsonb_build_object('ok', v_row.status = p_status, 'code', 'already', 'status', v_row.status, 'outbox_id', v_row.id);
  end if;
  v_n := case when coalesce(v_row.attempts, 1) > 1 then ':' || v_row.attempts::text else '' end;
  if p_status = 'sent' then
    insert into applicant_messages (applicant_id, channel, direction, body, sent_at, source_ref, direction_fixed, sent_by)
    values (v_row.applicant_id, 'line', 'out', left(v_row.body, 8000), now(), 'outbox:' || v_row.id::text, true, v_row.actor_id)
    on conflict (source_ref) do nothing
    returning id into v_msg;
    update applicants set updated_at = now(),
           last_actor_id = coalesce(v_row.actor_id, last_actor_id),
           last_actor_at = case when v_row.actor_id is not null then now() else last_actor_at end,
           interview_sent_at = case when v_row.purpose = 'interview_notice' then now() else interview_sent_at end
     where id = v_row.applicant_id;
    update applicant_outbox set status = 'sent', sent_at = now(), message_id = v_msg, response = p_response, error = null, updated_at = now() where id = p_outbox;
    v_op := recruit_op_log(v_row.applicant_id, 'message_send', v_row.actor_id, v_row.via, 'send:' || v_row.id::text || ':sent' || v_n, '{}'::jsonb,
                           jsonb_build_object('outbox_id', v_row.id, 'purpose', v_row.purpose, 'mode', 'live', 'message_id', v_msg, 'chars', length(v_row.body), 'attempts', v_row.attempts), 'done', null, null);
  else
    update applicant_outbox set status = p_status, error = left(coalesce(p_error, ''), 500), response = p_response, updated_at = now() where id = p_outbox;
    v_op := recruit_op_log(v_row.applicant_id, 'message_send', v_row.actor_id, v_row.via, 'send:' || v_row.id::text || ':' || p_status || v_n, '{}'::jsonb,
                           jsonb_build_object('outbox_id', v_row.id, 'purpose', v_row.purpose, 'mode', 'live', 'status', p_status, 'attempts', v_row.attempts), 'failed',
                           left(case when p_status = 'unknown' then '結果不明: ' else '' end || coalesce(p_error, ''), 500), null);
  end if;
  return jsonb_build_object('ok', true, 'code', p_status, 'status', p_status, 'outbox_id', v_row.id, 'message_id', v_msg);
end $$;

-- 送り直しの窓に出す材料（読むだけ）。本文は、採用の権限があり、その応募者を見られる人にだけ返す
create or replace function public.recruit_send_retry_info(p_outbox uuid, p_actor uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_row applicant_outbox%rowtype; v_a record; v_cfg jsonb := recruit_actions_cfg(); v_test boolean; v_linked boolean; v_code text := 'ok';
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  select * into v_row from applicant_outbox where id = p_outbox;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '送信の記録が見つかりません'); end if;
  select a.id, a.name, a.store_id, a.answers, a.line_user_id into v_a from applicants a where a.id = v_row.applicant_id;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;
  if not (coalesce((select u.is_active from users u where u.id = p_actor), false) and has_feature(p_actor, 'recruit') and can_see_applicant(p_actor, v_a.store_id)) then
    return jsonb_build_object('ok', false, 'code', 'denied', 'message', '権限がありません');
  end if;
  v_test := coalesce(v_a.answers ->> '_test', '') = 'true';
  v_linked := coalesce(btrim(coalesce(v_a.line_user_id, '')), '') <> '';
  if v_row.status not in ('failed', 'unknown') then v_code := 'not_retryable';
  elsif not (v_cfg ->> 'send_enabled')::boolean and not v_test then v_code := 'disabled';
  elsif not v_linked then v_code := 'not_linked';
  end if;
  return jsonb_build_object('ok', true, 'can_retry', v_code = 'ok', 'code', v_code, 'status', v_row.status, 'purpose', v_row.purpose, 'attempts', v_row.attempts,
    'applicant_id', v_row.applicant_id, 'applicant_name', v_a.name, 'body', v_row.body, 'line_mode', v_cfg ->> 'line_mode', 'failed_at', v_row.updated_at,
    'message', case v_code when 'not_retryable' then case v_row.status when 'sent' then 'この送信は、すでに送信済みです' when 'sending' then 'この送信は、いま処理中です' else 'この送信は、送り直しの対象ではありません' end
                           when 'disabled' then '応募者への送信は、まだ使えません（送信のスイッチが OFF です）'
                           when 'not_linked' then 'この応募者は LINE と連携していないため、ここからは送れません' else null end);
end $$;

-- 送り直しの始まり: 権限・スイッチ・状態を確かめて、同じ行を「送信中」に戻す（再送の鍵は変えない＝最初の送信が実は届いていた場合、LINE の側で二重にならない）
-- 返す形（code）: send（送ってよい。"to"・"text"・"retry_key"・"outbox_id"）／dry（試しモード。何も変えない）／replayed／denied・disabled・not_linked・not_retryable・not_found
create or replace function public.recruit_send_retry_begin(p_outbox uuid, p_request_key text, p_actor uuid, p_via text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_row applicant_outbox%rowtype; v_a record; v_cfg jsonb := recruit_actions_cfg(); v_key text := btrim(coalesce(p_request_key, '')); v_prev applicant_ops%rowtype; v_test boolean; v_op uuid; v_name text;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  if p_via is null or p_via not in ('slack', 'web', 'app') then raise exception 'p_via が正しくありません'; end if;
  if length(v_key) < 8 or length(v_key) > 200 then raise exception '依頼の鍵（p_request_key）が正しくありません'; end if;
  select b.applicant_id into v_a from applicant_outbox b where b.id = p_outbox;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '送信の記録が見つかりません'); end if;
  -- 応募者の行 → 送信箱の行の順に押さえる（ふつうの送信と同じ順）
  select a.id, a.name, a.store_id, a.answers, a.line_user_id into v_a from applicants a where a.id = v_a.applicant_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;
  select * into v_row from applicant_outbox where id = p_outbox for update;

  select * into v_prev from applicant_ops where request_key = v_key;
  if found then
    return jsonb_build_object('ok', false, 'code', 'replayed', 'replayed', true, 'status', v_row.status, 'outbox_id', v_row.id, 'message', 'この操作は、すでに受け付けています（もう一度は送りません）');
  end if;
  if not (coalesce((select u.is_active from users u where u.id = p_actor), false) and has_feature(p_actor, 'recruit') and can_see_applicant(p_actor, v_a.store_id)) then
    v_op := recruit_op_log(v_a.id, 'message_retry', p_actor, p_via, v_key, '{}'::jsonb, jsonb_build_object('outbox_id', v_row.id), 'denied', 'no_permission', null);
    return jsonb_build_object('ok', false, 'code', 'denied', 'message', '権限がありません');
  end if;
  if v_row.status not in ('failed', 'unknown') then
    return jsonb_build_object('ok', false, 'code', 'not_retryable', 'status', v_row.status,
      'message', case v_row.status when 'sent' then 'この送信は、すでに送信済みです' when 'sending' then 'この送信は、いま処理中です' else 'この送信は、送り直しの対象ではありません' end);
  end if;
  v_test := coalesce(v_a.answers ->> '_test', '') = 'true';
  if not (v_cfg ->> 'send_enabled')::boolean and not v_test then
    return jsonb_build_object('ok', false, 'code', 'disabled', 'message', '応募者への送信は、まだ使えません（送信のスイッチが OFF です）');
  end if;
  if coalesce(btrim(coalesce(v_a.line_user_id, '')), '') = '' then
    return jsonb_build_object('ok', false, 'code', 'not_linked', 'message', 'この応募者は LINE と連携していないため、ここからは送れません');
  end if;
  select u.name into v_name from users u where u.id = p_actor;
  if v_cfg ->> 'line_mode' <> 'live' then
    v_op := recruit_op_log(v_a.id, 'message_retry', p_actor, p_via, v_key, jsonb_build_object('status', v_row.status), jsonb_build_object('outbox_id', v_row.id, 'mode', 'dry'), 'noop', null, '試しモード（LINE は送っていない）');
    return jsonb_build_object('ok', true, 'code', 'dry', 'outbox_id', v_row.id, 'mode', 'dry', 'status', v_row.status, 'actor_name', v_name, 'message', '試しモードのため、LINE は送っていません');
  end if;
  update applicant_outbox set status = 'sending', attempts = coalesce(attempts, 1) + 1, error = null, updated_at = now() where id = p_outbox;
  v_op := recruit_op_log(v_a.id, 'message_retry', p_actor, p_via, v_key, jsonb_build_object('status', v_row.status, 'attempts', v_row.attempts),
                         jsonb_build_object('outbox_id', v_row.id, 'mode', 'live', 'attempts', coalesce(v_row.attempts, 1) + 1), 'done', null, null);
  return jsonb_build_object('ok', true, 'code', 'send', 'outbox_id', v_row.id, 'applicant_id', v_a.id, 'mode', 'live', 'status', 'sending', 'retry_key', v_row.retry_key,
    'to', v_a.line_user_id, 'text', v_row.body, 'applicant_name', v_a.name, 'actor_name', v_name, 'purpose', v_row.purpose);
end $$;

-- ============ 3. カレンダーの登録のやり直し（面接の確定は、そのまま。予定と Meet だけ、もう一度） ============
-- 始まり: 権限（社員採用は、面接の確定と同じ決まり）・スイッチ・同時の操作を確かめて、面接の操作として「処理中」の 1 行を入れる（段の記録と終わりは、第 2 弾の関数をそのまま使う）
create or replace function public.recruit_calendar_retry_begin(p_applicant uuid, p_request_key text, p_actor uuid, p_via text, p_notify boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := recruit_actions_cfg(); v_a record; v_prev applicant_ops%rowtype; v_last applicant_ops%rowtype; v_key text := btrim(coalesce(p_request_key, ''));
  v_test boolean; v_pl jsonb := null; v_id uuid; v_ceo_only boolean; v_event text; v_before jsonb; v_after jsonb;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  if p_via is null or p_via not in ('slack', 'web', 'app') then raise exception 'p_via が正しくありません'; end if;
  if length(v_key) < 8 or length(v_key) > 200 then raise exception '依頼の鍵（p_request_key）が正しくありません'; end if;
  select a.id, a.name, a.store_id, a.form_key, a.answers, a.assignee_id, a.line_user_id, a.interview_at, a.interview_mode, a.interview_place, a.interview_address, a.interview_url, a.interview_event_id
    into v_a from applicants a where a.id = p_applicant for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;
  update applicant_ops set result = 'failed', error = '処理が途中で止まりました' where applicant_id = p_applicant and op in ('interview_confirm', 'interview_cancel')
     and result = 'processing' and created_at < clock_timestamp() - interval '2 minutes';
  select * into v_prev from applicant_ops where request_key = v_key;
  if found then
    return jsonb_build_object('ok', v_prev.result in ('done', 'partial'), 'code', 'replayed', 'replayed', true, 'op_id', v_prev.id, 'result', v_prev.result,
      'message', case v_prev.result when 'processing' then '処理中です（もう一度は実行しません）' when 'done' then '処理済みです' else 'この操作は、すでに受け付けています' end);
  end if;
  v_before := jsonb_build_object('interview_at', v_a.interview_at, 'interview_event_id', v_a.interview_event_id, 'has_url', coalesce(btrim(coalesce(v_a.interview_url, '')), '') <> '');
  v_after := jsonb_build_object('retry', true, 'interview_at', v_a.interview_at, 'interview_mode', v_a.interview_mode, 'interview_place', v_a.interview_place, 'notify', coalesce(p_notify, false));
  if not (coalesce((select u.is_active from users u where u.id = p_actor), false) and has_feature(p_actor, 'recruit') and can_see_applicant(p_actor, v_a.store_id)) then
    v_id := recruit_op_log(p_applicant, 'interview_confirm', p_actor, p_via, v_key, v_before, v_after, 'denied', 'no_permission', null);
    return jsonb_build_object('ok', false, 'code', 'denied', 'message', '権限がありません');
  end if;
  v_ceo_only := coalesce((select s.value -> 'interview_shain_ceo_only' <> 'false'::jsonb from app_settings s where s.key = 'recruit_actions'), true);
  if coalesce(v_a.form_key, '') = 'shain' and v_ceo_only and not coalesce((select u.role = 'CEO' or u.is_master from users u where u.id = p_actor), false) then
    v_id := recruit_op_log(p_applicant, 'interview_confirm', p_actor, p_via, v_key, v_before, v_after, 'denied', 'employee_ceo_only', null);
    return jsonb_build_object('ok', false, 'code', 'denied', 'message', '社員採用の面接の操作は、社長だけが行えます');
  end if;
  v_test := coalesce(v_a.answers ->> '_test', '') = 'true';
  if not v_test and not ((v_cfg ->> 'send_enabled')::boolean and v_cfg ->> 'calendar_mode' = 'live') then
    return jsonb_build_object('ok', false, 'code', 'disabled', 'message', 'カレンダーの登録は、まだここからは使えません（スイッチが OFF、または、カレンダーが試しモードです）。管理画面から操作してください');
  end if;
  if v_a.interview_at is null or coalesce(v_a.interview_mode, '') not in ('online', 'onsite') then
    return jsonb_build_object('ok', false, 'code', 'no_interview', 'message', '面接の日程が入っていません（または、やり方が決まっていません）');
  end if;
  if exists (select 1 from applicant_ops o where o.applicant_id = p_applicant and o.op in ('interview_confirm', 'interview_cancel') and o.result = 'processing') then
    return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'ほかの人が、この応募者の面接を操作しています。少し待って、内容を確かめてください');
  end if;
  if v_a.interview_mode = 'onsite' then
    select e into v_pl from app_settings s, jsonb_array_elements(case when jsonb_typeof(s.value) = 'array' then s.value else '[]'::jsonb end) e
     where s.key = 'interview_places' and e ->> 'name' = v_a.interview_place limit 1;
  end if;
  -- いまの予定の番号。無ければ、直前の操作が「予定は作れたが、保存まで行かなかった」ときの番号（面接の確定の始まりと同じ決まり）
  v_event := nullif(btrim(coalesce(v_a.interview_event_id, '')), '');
  if v_event is null then
    select * into v_last from applicant_ops o where o.applicant_id = p_applicant and o.op in ('interview_confirm', 'interview_cancel') and o.result in ('failed', 'partial', 'done')
     order by o.created_at desc, o.id desc limit 1;
    if found and v_last.op = 'interview_confirm' and coalesce(v_last.steps -> 'calendar' ->> 'mode', '') = 'live' and coalesce(v_last.steps -> 'calendar' ->> 'ok', '') = 'true'
       and coalesce(v_last.steps -> 'save' ->> 'ok', '') <> 'true' then
      v_event := nullif(v_last.steps -> 'calendar' ->> 'event_id', '');
    end if;
  end if;
  insert into applicant_ops (applicant_id, op, actor_id, via, request_key, before_state, after_state, result, created_at)
  values (p_applicant, 'interview_confirm', p_actor, p_via, v_key, v_before, v_after, 'processing', clock_timestamp())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'code', 'go', 'op_id', v_id, 'kind', 'calendar_retry', 'is_test', v_test,
    'calendar_mode', v_cfg ->> 'calendar_mode', 'line_mode', v_cfg ->> 'line_mode', 'applicant_name', v_a.name,
    'linked', coalesce(btrim(coalesce(v_a.line_user_id, '')), '') <> '', 'event_id', v_event, 'current_url', v_a.interview_url,
    'interviewer_name', (select u.name from users u where u.id = v_a.assignee_id), 'actor_name', (select u.name from users u where u.id = p_actor),
    'at', v_a.interview_at, 'mode', v_a.interview_mode, 'place', v_a.interview_place, 'address', coalesce(nullif(btrim(coalesce(v_a.interview_address, '')), ''), v_pl ->> 'address'),
    'place_note', v_pl ->> 'note', 'notify', coalesce(p_notify, false));
end $$;

-- 保存: 予定の番号と（オンラインで新しく発行できたときの）URL だけを入れる。面接日時・やり方・場所・確定した人・状態は変えない。お知らせも作らない
create or replace function public.recruit_calendar_retry_save(p_op uuid, p_url text default null, p_event_id text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_o applicant_ops%rowtype; v_a record;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  select * into v_o from applicant_ops where id = p_op for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_processing', 'message', '処理中の操作ではありません'); end if;
  if v_o.result <> 'processing' or v_o.op <> 'interview_confirm' or coalesce(v_o.after_state ->> 'retry', '') <> 'true' then
    return jsonb_build_object('ok', false, 'code', 'not_processing', 'message', '処理中の操作ではありません');
  end if;
  update applicants set
    interview_event_id = coalesce(nullif(btrim(coalesce(p_event_id, '')), ''), interview_event_id),
    interview_url = case when interview_mode = 'online' then coalesce(nullif(btrim(coalesce(p_url, '')), ''), interview_url) else interview_url end,
    updated_at = now(), last_actor_id = v_o.actor_id, last_actor_at = now()
   where id = v_o.applicant_id
   returning name, interview_at, interview_mode, interview_place, interview_address, interview_url into v_a;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;
  update applicant_ops set steps = steps || '{"save": {"ok": true}}'::jsonb where id = p_op;
  return jsonb_build_object('ok', true, 'code', 'saved', 'kind', 'calendar_retry', 'applicant_name', v_a.name, 'interview_at', v_a.interview_at, 'interview_mode', v_a.interview_mode,
    'interview_place', v_a.interview_place, 'interview_address', v_a.interview_address, 'interview_url', v_a.interview_url);
end $$;

-- ============ 4. 権限 ============
revoke all on function public.recruit_alerts_on(), public.recruit_alerts_set(boolean), public.recruit_alerts_trigger(),
  public.recruit_send_retry_info(uuid, uuid), public.recruit_send_retry_begin(uuid, text, uuid, text),
  public.recruit_calendar_retry_begin(uuid, text, uuid, text, boolean), public.recruit_calendar_retry_save(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.recruit_alerts_on(), public.recruit_send_retry_info(uuid, uuid), public.recruit_send_retry_begin(uuid, text, uuid, text),
  public.recruit_calendar_retry_begin(uuid, text, uuid, text, boolean), public.recruit_calendar_retry_save(uuid, text, text) to service_role;
grant execute on function public.recruit_alerts_set(boolean) to authenticated, service_role;

-- ============ 5. 定期実行（毎時 20 分・日本時間 8〜22 時。スイッチと設定がそろうまで、呼ばれても何もせずに戻る） ============
do $$
begin
  if exists (select 1 from cron.job where jobname = 'recruit-unhandled-alert') then perform cron.unschedule('recruit-unhandled-alert'); end if;
  perform cron.schedule('recruit-unhandled-alert', '20 23,0-13 * * *', $cmd$select public.recruit_alerts_trigger()$cmd$);
end $$;

-- ============ 確認用（読むだけ） ============
-- select recruit_alerts_on();                                   -- false（スイッチと予備の担当がそろうまで）
-- select jobname, schedule, active from cron.job where jobname = 'recruit-unhandled-alert';
