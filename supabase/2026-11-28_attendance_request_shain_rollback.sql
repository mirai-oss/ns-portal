-- 戻し
begin;

CREATE OR REPLACE FUNCTION public.sf_attendance_request_submit(p_actor uuid, p_kind text, p_store_id uuid, p_user_id uuid, p_work_date date, p_clock_in timestamp with time zone, p_clock_out timestamp with time zone, p_reason text, p_break_start_1 timestamp with time zone DEFAULT NULL::timestamp with time zone, p_break_end_1 timestamp with time zone DEFAULT NULL::timestamp with time zone, p_break_start_2 timestamp with time zone DEFAULT NULL::timestamp with time zone, p_break_end_2 timestamp with time zone DEFAULT NULL::timestamp with time zone, p_via text DEFAULT 'form'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_name text; v_min numeric; v_break numeric := 0; l labor_cost_daily%rowtype; v_id uuid; r sf_attendance_requests%rowtype; v_cnt int;
begin
  select name into v_name from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '申請者が管理システムに見つかりません'); end if;
  if p_kind not in ('add','fix') then return jsonb_build_object('ok', false, 'code', 'invalid', 'message', '種類は「勤怠追加」か「勤怠修正」です'); end if;
  if not (sf_can_manage_as(p_actor, p_store_id) or p_actor = p_user_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この店舗の勤怠を申請する権限がありません');
  end if;
  if not exists (select 1 from users where id = p_user_id and is_active) then
    return jsonb_build_object('ok', false, 'code', 'invalid', 'message', '対象の従業員が見つかりません');
  end if;
  if not exists (select 1 from stores where id = p_store_id and is_active) then
    return jsonb_build_object('ok', false, 'code', 'invalid', 'message', '店舗が見つかりません');
  end if;
  if p_clock_in is null or p_clock_out is null or p_clock_out <= p_clock_in then
    return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '退勤は出勤より後の時刻にしてください');
  end if;
  v_min := extract(epoch from (p_clock_out - p_clock_in)) / 60;
  if v_min > 24 * 60 then return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '勤務は 24 時間以内にしてください'); end if;
  if (p_clock_in at time zone 'Asia/Tokyo')::date not between p_work_date - 1 and p_work_date + 1 then
    return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '出勤日が勤務日と離れすぎています');
  end if;
  if p_work_date > (now() at time zone 'Asia/Tokyo')::date then
    return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '未来の日付は申請できません');
  end if;
  if (p_break_start_1 is null) <> (p_break_end_1 is null) or (p_break_start_2 is null) <> (p_break_end_2 is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid_break', 'message', '休憩は開始と終了の両方を入れてください');
  end if;
  if p_break_start_1 is null and p_break_start_2 is not null then
    return jsonb_build_object('ok', false, 'code', 'invalid_break', 'message', '休憩2 だけは入れられません（休憩1 に入れてください）');
  end if;
  if p_break_start_1 is not null then
    if p_break_end_1 <= p_break_start_1 or p_break_start_1 < p_clock_in or p_break_end_1 > p_clock_out then
      return jsonb_build_object('ok', false, 'code', 'invalid_break', 'message', '休憩1 は出勤〜退勤の間で、終了を開始より後にしてください');
    end if;
    v_break := v_break + extract(epoch from (p_break_end_1 - p_break_start_1)) / 60;
  end if;
  if p_break_start_2 is not null then
    if p_break_end_2 <= p_break_start_2 or p_break_start_2 < p_break_end_1 or p_break_end_2 > p_clock_out then
      return jsonb_build_object('ok', false, 'code', 'invalid_break', 'message', '休憩2 は休憩1 の後〜退勤の間で、終了を開始より後にしてください');
    end if;
    v_break := v_break + extract(epoch from (p_break_end_2 - p_break_start_2)) / 60;
  end if;
  if v_break > 4 * 60 then return jsonb_build_object('ok', false, 'code', 'invalid_break', 'message', '休憩の合計は 4 時間以内にしてください'); end if;
  if length(coalesce(trim(p_reason), '')) not between 1 and 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_reason', 'message', '理由を 300 字以内で入れてください');
  end if;
  if exists (select 1 from sf_attendance_requests where user_id = p_user_id and work_date = p_work_date and status = 'pending') then
    return jsonb_build_object('ok', false, 'code', 'already', 'message', 'この人のこの日の申請が承認待ちです。承認か却下のあとに出し直してください');
  end if;

  if p_kind = 'fix' then
    select count(*) into v_cnt from labor_cost_daily where user_id = p_user_id and work_date = p_work_date;
    if v_cnt = 0 then
      return jsonb_build_object('ok', false, 'code', 'no_record', 'message', 'その日の勤怠実績がありません。「勤怠追加」で申請してください');
    end if;
    select * into l from labor_cost_daily where user_id = p_user_id and work_date = p_work_date
      order by (store_id = p_store_id) desc, clock_in limit 1;
    if l.store_id <> p_store_id then
      return jsonb_build_object('ok', false, 'code', 'other_store', 'message', format('その日の勤怠実績は %s のものです。店舗を選び直してください', (select name from stores where id = l.store_id)));
    end if;
  else
    if exists (select 1 from labor_cost_daily where user_id = p_user_id and work_date = p_work_date and store_id = p_store_id) then
      return jsonb_build_object('ok', false, 'code', 'exists', 'message', 'その日の勤怠実績はすでにあります。「勤怠修正」で申請してください');
    end if;
  end if;

  insert into sf_attendance_requests (kind, store_id, user_id, work_date, labor_cost_daily_id, before, clock_in, clock_out,
      break_start_1, break_end_1, break_start_2, break_end_2, break_minutes, reason, requested_by, requested_via)
  values (p_kind, p_store_id, p_user_id, p_work_date, case when p_kind = 'fix' then l.id end,
      case when p_kind = 'fix' then jsonb_build_object('clock_in', l.clock_in, 'clock_out', l.clock_out, 'worked_minutes', l.worked_minutes,
        'break_start_1', l.break_start_1, 'break_end_1', l.break_end_1, 'break_start_2', l.break_start_2, 'break_end_2', l.break_end_2, 'break_minutes', l.break_minutes) end,
      p_clock_in, p_clock_out, p_break_start_1, p_break_end_1, p_break_start_2, p_break_end_2, round(v_break), trim(p_reason), p_actor, coalesce(p_via, 'form'))
  returning * into r;
  return jsonb_build_object('ok', true, 'request_id', r.id, 'kind', r.kind, 'summary', sf_attendance_request_summary(r), 'actor_name', v_name,
    'before', case when p_kind = 'fix' then format('%s−%s（%s）', to_char(l.clock_in at time zone 'Asia/Tokyo', 'HH24:MI'),
        case when (l.clock_out at time zone 'Asia/Tokyo')::date > (l.clock_in at time zone 'Asia/Tokyo')::date then '翌' else '' end || coalesce(to_char(l.clock_out at time zone 'Asia/Tokyo', 'HH24:MI'), '退勤なし'),
        sf_attendance_break_text(l.break_start_1, l.break_end_1, l.break_start_2, l.break_end_2)) end,
    'reason', r.reason);
end $function$;

CREATE OR REPLACE FUNCTION public.sf_attendance_request_submit_delete(p_actor uuid, p_store_id uuid, p_user_id uuid, p_work_date date, p_reason text, p_via text DEFAULT 'form'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_name text; l labor_cost_daily%rowtype; r sf_attendance_requests%rowtype; v_cnt int;
begin
  select name into v_name from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '申請者が管理システムに見つかりません'); end if;
  if not (sf_can_manage_as(p_actor, p_store_id) or p_actor = p_user_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この店舗の勤怠を申請する権限がありません');
  end if;
  if not exists (select 1 from users where id = p_user_id and is_active) then
    return jsonb_build_object('ok', false, 'code', 'invalid', 'message', '対象の従業員が見つかりません');
  end if;
  if not exists (select 1 from stores where id = p_store_id and is_active) then
    return jsonb_build_object('ok', false, 'code', 'invalid', 'message', '店舗が見つかりません');
  end if;
  if p_work_date is null or p_work_date > (now() at time zone 'Asia/Tokyo')::date then
    return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '未来の日付は申請できません');
  end if;
  if length(coalesce(trim(p_reason), '')) not between 1 and 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_reason', 'message', '取消の理由を 300 字以内で入れてください（理由は必須です）');
  end if;
  if exists (select 1 from sf_attendance_requests where user_id = p_user_id and work_date = p_work_date and status = 'pending') then
    return jsonb_build_object('ok', false, 'code', 'already', 'message', 'この人のこの日の申請が承認待ちです。承認か却下のあとに出し直してください');
  end if;
  select count(*) into v_cnt from labor_cost_daily where user_id = p_user_id and work_date = p_work_date;
  if v_cnt = 0 then return jsonb_build_object('ok', false, 'code', 'no_record', 'message', 'その日の勤怠実績がありません（取り消すものがありません）'); end if;
  select * into l from labor_cost_daily where user_id = p_user_id and work_date = p_work_date order by (store_id = p_store_id) desc, clock_in limit 1;
  if l.store_id <> p_store_id then
    return jsonb_build_object('ok', false, 'code', 'other_store', 'message', format('その日の勤怠実績は %s のものです。店舗を選び直してください', (select name from stores where id = l.store_id)));
  end if;
  insert into sf_attendance_requests (kind, store_id, user_id, work_date, labor_cost_daily_id, before, before_meta, clock_in, clock_out,
      break_start_1, break_end_1, break_start_2, break_end_2, break_minutes, reason, requested_by, requested_via)
  values ('delete', p_store_id, p_user_id, p_work_date, l.id,
      jsonb_build_object('clock_in', l.clock_in, 'clock_out', l.clock_out, 'worked_minutes', l.worked_minutes,
        'break_start_1', l.break_start_1, 'break_end_1', l.break_end_1, 'break_start_2', l.break_start_2, 'break_end_2', l.break_end_2, 'break_minutes', l.break_minutes),
      jsonb_build_object('exists', true, 'labor_cost_daily_id', l.id, 'smaregi_shift_result_id', l.smaregi_shift_result_id,
        'source', l.source, 'row_updated_at', l.updated_at, 'manual_fixed', l.manual_fixed_at is not null, 'taken_at', now()),
      l.clock_in, case when l.clock_out is not null and l.clock_out > l.clock_in then l.clock_out else l.clock_in + interval '1 minute' end,
      l.break_start_1, l.break_end_1, l.break_start_2, l.break_end_2, coalesce(l.break_minutes, 0), trim(p_reason), p_actor, coalesce(p_via, 'form'))
  returning * into r;
  return jsonb_build_object('ok', true, 'request_id', r.id, 'kind', r.kind, 'summary', sf_attendance_request_summary(r), 'actor_name', v_name,
    'before', format('%s−%s（%s）', to_char(l.clock_in at time zone 'Asia/Tokyo', 'HH24:MI'),
        case when (l.clock_out at time zone 'Asia/Tokyo')::date > (l.clock_in at time zone 'Asia/Tokyo')::date then '翌' else '' end || coalesce(to_char(l.clock_out at time zone 'Asia/Tokyo', 'HH24:MI'), '退勤なし'),
        sf_attendance_break_text(l.break_start_1, l.break_end_1, l.break_start_2, l.break_end_2)),
    'reason', r.reason);
end $function$;

CREATE OR REPLACE FUNCTION public.sf_attendance_fix_request(p_alert_id uuid, p_actor uuid, p_clock_in timestamp with time zone, p_clock_out timestamp with time zone, p_reason text, p_via text DEFAULT 'slack'::text, p_break_start_1 timestamp with time zone DEFAULT NULL::timestamp with time zone, p_break_end_1 timestamp with time zone DEFAULT NULL::timestamp with time zone, p_break_start_2 timestamp with time zone DEFAULT NULL::timestamp with time zone, p_break_end_2 timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_set jsonb; a sf_attendance_alerts%rowtype; v_res jsonb; v_req uuid; v_name text; v_prev text;
begin
  select value into v_set from app_settings where key = 'attendance_request_flow';
  if not (coalesce((v_set -> 'thread') = 'true'::jsonb, false) and coalesce((v_set -> 'two_stage') = 'true'::jsonb, false)) then
    return public.sf_attendance_fix_request_legacy(p_alert_id, p_actor, p_clock_in, p_clock_out, p_reason, p_via,
      p_break_start_1, p_break_end_1, p_break_start_2, p_break_end_2);
  end if;
  select name into v_name from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  select * into a from sf_attendance_alerts where id = p_alert_id for update;   -- 行ロック: 同時に 2 回押されても、申請は 1 つだけ
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この勤怠確認は見つかりません'); end if;
  if a.request_id is not null and a.status = 'fix_requested' then
    return jsonb_build_object('ok', false, 'code', 'already', 'message', 'この勤怠確認は、すでに修正申請が出ています（承認待ち）', 'request_id', a.request_id);
  end if;
  if a.status not in ('open', 'confirmed') then
    select name into v_prev from users where id = coalesce(a.requested_by, a.decided_by);
    return jsonb_build_object('ok', false, 'code', 'already', 'message', format('この勤怠確認はすでに処理されています（%s・%s）', a.status, coalesce(v_prev, '-')));
  end if;
  if not sf_can_manage_as(p_actor, a.store_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この店舗の勤怠を修正する権限がありません');
  end if;
  -- 時刻・休憩・理由の検査と、申請の作成（2 段階の流れ・一次承認者の決定は、申請の表のトリガーが行う）
  v_res := public.sf_attendance_request_submit(p_actor, 'fix', a.store_id, a.user_id, a.work_date, p_clock_in, p_clock_out, p_reason,
    p_break_start_1, p_break_end_1, p_break_start_2, p_break_end_2, coalesce(p_via, 'form'));
  if coalesce((v_res ->> 'ok')::boolean, false) is not true then return v_res; end if;
  v_req := (v_res ->> 'request_id')::uuid;
  update sf_attendance_alerts
     set status = 'fix_requested', request_id = v_req, proposed_clock_in = p_clock_in, proposed_clock_out = p_clock_out, fix_reason = trim(p_reason),
         proposed_break_start_1 = p_break_start_1, proposed_break_end_1 = p_break_end_1,
         proposed_break_start_2 = p_break_start_2, proposed_break_end_2 = p_break_end_2,
         requested_by = p_actor, requested_at = now(), updated_at = now()
   where id = a.id;
  return jsonb_build_object('ok', true, 'alert_id', a.id, 'request_id', v_req, 'summary', sf_attendance_alert_summary(a), 'actor_name', v_name,
    'proposed', v_res ->> 'summary', 'reason', trim(p_reason), 'notification_ids', to_jsonb(a.notification_ids));
end $function$;

CREATE OR REPLACE FUNCTION public.sf_attendance_delete_request(p_alert_id uuid, p_actor uuid, p_reason text, p_via text DEFAULT 'slack'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare a sf_attendance_alerts%rowtype; v_name text; v_prev text;
begin
  select name into v_name from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  select * into a from sf_attendance_alerts where id = p_alert_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この勤怠確認は見つかりません'); end if;
  if a.status not in ('open', 'confirmed') then
    select name into v_prev from users where id = coalesce(a.requested_by, a.decided_by);
    return jsonb_build_object('ok', false, 'code', 'already', 'message', format('この勤怠確認はすでに処理されています（%s・%s）', a.status, coalesce(v_prev, '-')));
  end if;
  if not sf_can_manage_as(p_actor, a.store_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この店舗の勤怠を直す権限がありません');
  end if;
  if a.labor_cost_daily_id is null or not exists (select 1 from labor_cost_daily where id = a.labor_cost_daily_id) then
    return jsonb_build_object('ok', false, 'code', 'no_record', 'message', '元の勤怠実績がもう無いため削除できません');
  end if;
  if length(coalesce(trim(p_reason), '')) not between 1 and 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_reason', 'message', '削除の理由を 300 字以内で入れてください');
  end if;
  update sf_attendance_alerts
     set status = 'fix_requested', request_kind = 'delete', fix_reason = trim(p_reason),
         proposed_clock_in = null, proposed_clock_out = null,
         proposed_break_start_1 = null, proposed_break_end_1 = null, proposed_break_start_2 = null, proposed_break_end_2 = null,
         requested_by = p_actor, requested_at = now(), updated_at = now()
   where id = a.id;
  return jsonb_build_object('ok', true, 'alert_id', a.id, 'request_kind', 'delete', 'summary', sf_attendance_alert_summary(a), 'actor_name', v_name,
    'proposed', '打刻削除（この日の勤務を取り消す）', 'reason', trim(p_reason), 'notification_ids', to_jsonb(a.notification_ids));
end $function$;

CREATE OR REPLACE FUNCTION public.sf_attendance_form_day(p_store_id uuid, p_work_date date)
 RETURNS TABLE(labor_cost_daily_id uuid, user_id uuid, name text, clock_in text, clock_out text, break_start_1 text, break_end_1 text, break_start_2 text, break_end_2 text, worked_minutes integer, break_minutes integer, locked boolean, pending boolean, source text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select l.id, l.user_id, u.name,
         to_char(l.clock_in  at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI:SS'),
         to_char(l.clock_out at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI:SS'),
         to_char(l.break_start_1 at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI:SS'),
         to_char(l.break_end_1   at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI:SS'),
         to_char(l.break_start_2 at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI:SS'),
         to_char(l.break_end_2   at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI:SS'),
         l.worked_minutes::int, l.break_minutes::int, (l.manual_fixed_at is not null),
         exists (select 1 from sf_attendance_requests r where r.user_id = l.user_id and r.work_date = l.work_date and r.store_id = l.store_id and r.status = 'pending'),
         l.source
  from labor_cost_daily l join users u on u.id = l.user_id
  where l.store_id = p_store_id and l.work_date = p_work_date
    and (sf_can_manage(p_store_id) or l.user_id = auth.uid())
  order by l.clock_in nulls last, u.name;
$function$;

CREATE OR REPLACE FUNCTION public.sf_attendance_form_staff(p_store_id uuid)
 RETURNS TABLE(id uuid, name text, role text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select u.id, u.name, u.role
  from users u join user_stores us on us.user_id = u.id
  where us.store_id = p_store_id and u.is_active
    and (sf_can_manage(p_store_id) or exists (select 1 from user_stores x where x.user_id = auth.uid() and x.store_id = p_store_id))
  order by u.name;
$function$;
drop function if exists public.sf_can_request_as(uuid, uuid);
commit;
