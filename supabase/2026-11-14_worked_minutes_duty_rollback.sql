-- =============================================================
-- 2026-11-14_worked_minutes_duty.sql を戻す（変更前の 3 関数の定義を、そのまま入れ直す）  ★実行は別途承認
--   入れてあるのは、リポジトリの次の場所の定義を 1 文字も変えずに写したもの:
--     sf_attendance_fix_decide ............ supabase/2026-11-08_attendance_delete_request.sql 64〜123 行（権限は 2026-11-07_sf_attendance_alerts.sql 248〜249 行）
--     sf_attendance_request_decide ........ supabase/2026-11-07_sf_attendance_requests.sql 167〜215 行（権限は同じファイルの 216〜217 行）
--     attendance_break_autofill_finish .... supabase/2026-11-13_break_autofill.sql 165〜188 行（権限は同じファイルの 280〜284 行のうち、この関数の分）
--   このファイルは「本番の変更前の定義」との突き合わせにも使う（本体の md5: sf_attendance_fix_decide=324fc71a207d428e6ee1d342b6a592a7 ／ sf_attendance_request_decide=67a7546c934348c8ebd79e89b15fe0b6 ／ attendance_break_autofill_finish=cd99182628c239eb4423942460fff7c7）。
--   戻したあと: 承認のときに入る worked_minutes は、また実労働時間（退勤−出勤−休憩）になる。
--   データは変えない。2026-11-14 の適用から戻すまでのあいだに承認で入った値（拘束時間）は、そのまま残る（スマレジから取り込み直されれば拘束時間のまま＝取り込みと同じ）。
-- =============================================================

-- 1) 勤怠確認からの修正の承認
create or replace function public.sf_attendance_fix_decide(p_alert_id uuid, p_actor uuid, p_approve boolean, p_note text default null, p_via text default 'slack')
returns jsonb language plpgsql security definer set search_path = public as $$
declare a sf_attendance_alerts%rowtype; v_name text; v_master boolean; v_prev text; v_min numeric; v_break numeric; l labor_cost_daily%rowtype; v_est numeric; v_proposed text;
begin
  select name, coalesce(is_master, false) into v_name, v_master from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  if not v_master then return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', '承認できるのはマスターだけです'); end if;
  select * into a from sf_attendance_alerts where id = p_alert_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この修正申請は見つかりません'); end if;
  if a.status <> 'fix_requested' then
    select name into v_prev from users where id = a.decided_by;
    return jsonb_build_object('ok', false, 'code', 'already', 'message', format('この修正申請はすでに処理されています（%s・%s）', a.status, coalesce(v_prev, '-')));
  end if;

  if p_approve and a.request_kind = 'delete' then
    -- 打刻削除: 行の写しを控えてから、管理システムの勤怠実績と出勤記録を消す（スマレジ側は EF が deleted_shift_result_id で DELETE）
    select * into l from labor_cost_daily where id = a.labor_cost_daily_id for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'no_record', 'message', '元の勤怠実績が見つかりません（同期で消えた可能性）'); end if;
    update sf_attendance_alerts
       set deleted_shift_result_id = l.smaregi_shift_result_id, deleted_smaregi_staff_id = l.smaregi_staff_id, deleted_source = l.source, deleted_labor = to_jsonb(l),
           status = 'approved', decided_by = p_actor, decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), ''),
           applied_at = now(), updated_at = now()
     where id = a.id;
    delete from attendance_records where user_id = a.user_id and work_date = a.work_date;
    delete from labor_cost_daily where id = l.id;   -- FK は set null（アラート行は残る）
  elsif p_approve then
    select * into l from labor_cost_daily where id = a.labor_cost_daily_id for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'no_record', 'message', '元の勤怠実績が見つかりません（同期で消えた可能性）'); end if;
    v_break := coalesce(extract(epoch from (a.proposed_break_end_1 - a.proposed_break_start_1)) / 60, 0)
             + coalesce(extract(epoch from (a.proposed_break_end_2 - a.proposed_break_start_2)) / 60, 0);
    v_min := round(extract(epoch from (a.proposed_clock_out - a.proposed_clock_in)) / 60 - v_break);
    v_est := case when coalesce(l.worked_minutes, 0) > 0 and l.smaregi_estimate_cost is not null
                  then round(l.smaregi_estimate_cost * v_min / l.worked_minutes) else l.smaregi_estimate_cost end;
    update labor_cost_daily
       set orig_clock_in = coalesce(orig_clock_in, clock_in), orig_clock_out = coalesce(orig_clock_out, clock_out),
           orig_worked_minutes = coalesce(orig_worked_minutes, worked_minutes), orig_smaregi_estimate_cost = coalesce(orig_smaregi_estimate_cost, smaregi_estimate_cost),
           clock_in = a.proposed_clock_in, clock_out = a.proposed_clock_out, worked_minutes = v_min, smaregi_estimate_cost = v_est,
           break_start_1 = a.proposed_break_start_1, break_end_1 = a.proposed_break_end_1,
           break_start_2 = a.proposed_break_start_2, break_end_2 = a.proposed_break_end_2, break_minutes = round(v_break),
           manual_fixed_at = now(), manual_fixed_by = p_actor, manual_fix_alert_id = a.id, updated_at = now()
     where id = l.id;
    update attendance_records set clock_in = a.proposed_clock_in, clock_out = a.proposed_clock_out
     where user_id = a.user_id and work_date = a.work_date;
    update sf_attendance_alerts set status = 'approved', decided_by = p_actor, decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), ''),
           applied_at = now(), updated_at = now() where id = a.id;
  else
    update sf_attendance_alerts set status = 'rejected', decided_by = p_actor, decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), ''),
           updated_at = now() where id = a.id;
  end if;
  v_proposed := case when a.request_kind = 'delete' then '打刻削除（この日の勤務を取り消す）'
    else format('%s−%s（%s）',
      to_char(a.proposed_clock_in at time zone 'Asia/Tokyo', 'HH24:MI'),
      case when (a.proposed_clock_out at time zone 'Asia/Tokyo')::date > (a.proposed_clock_in at time zone 'Asia/Tokyo')::date then '翌' else '' end
        || to_char(a.proposed_clock_out at time zone 'Asia/Tokyo', 'HH24:MI'),
      sf_attendance_break_text(a.proposed_break_start_1, a.proposed_break_end_1, a.proposed_break_start_2, a.proposed_break_end_2)) end;
  return jsonb_build_object('ok', true, 'alert_id', a.id, 'approved', p_approve, 'request_kind', a.request_kind, 'summary', sf_attendance_alert_summary(a), 'actor_name', v_name,
    'proposed', v_proposed, 'reason', a.fix_reason, 'note', nullif(trim(coalesce(p_note, '')), ''),
    'requested_by_name', (select name from users where id = a.requested_by),
    'notification_ids', to_jsonb(a.notification_ids), 'approval_notification_ids', to_jsonb(a.approval_notification_ids));
end $$;
revoke all on function public.sf_attendance_fix_decide(uuid, uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_fix_decide(uuid, uuid, boolean, text, text) to service_role;

-- 2) 勤怠フォームの申請の承認
create or replace function public.sf_attendance_request_decide(p_request_id uuid, p_actor uuid, p_approve boolean, p_note text default null, p_via text default 'slack')
returns jsonb language plpgsql security definer set search_path = public as $$
declare r sf_attendance_requests%rowtype; v_name text; v_master boolean; v_prev text; v_min numeric; l labor_cost_daily%rowtype; v_est numeric; v_new uuid;
begin
  select name, coalesce(is_master, false) into v_name, v_master from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  if not v_master then return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', '承認できるのはマスターだけです'); end if;
  select * into r from sf_attendance_requests where id = p_request_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この申請は見つかりません'); end if;
  if r.status <> 'pending' then
    select name into v_prev from users where id = r.decided_by;
    return jsonb_build_object('ok', false, 'code', 'already', 'message', format('この申請はすでに処理されています（%s・%s）', r.status, coalesce(v_prev, '-')));
  end if;
  if p_approve then
    v_min := round(extract(epoch from (r.clock_out - r.clock_in)) / 60 - r.break_minutes);
    if r.kind = 'fix' then
      select * into l from labor_cost_daily where id = r.labor_cost_daily_id for update;
      if not found then return jsonb_build_object('ok', false, 'code', 'no_record', 'message', '元の勤怠実績が見つかりません（同期で消えた可能性）'); end if;
      v_est := case when coalesce(l.worked_minutes, 0) > 0 and l.smaregi_estimate_cost is not null
                    then round(l.smaregi_estimate_cost * v_min / l.worked_minutes) else l.smaregi_estimate_cost end;
      update labor_cost_daily
         set orig_clock_in = coalesce(orig_clock_in, clock_in), orig_clock_out = coalesce(orig_clock_out, clock_out),
             orig_worked_minutes = coalesce(orig_worked_minutes, worked_minutes), orig_smaregi_estimate_cost = coalesce(orig_smaregi_estimate_cost, smaregi_estimate_cost),
             clock_in = r.clock_in, clock_out = r.clock_out, worked_minutes = v_min, smaregi_estimate_cost = v_est,
             break_start_1 = r.break_start_1, break_end_1 = r.break_end_1, break_start_2 = r.break_start_2, break_end_2 = r.break_end_2, break_minutes = r.break_minutes,
             manual_fixed_at = now(), manual_fixed_by = p_actor, updated_at = now()
       where id = l.id;
      v_new := l.id;
    else
      -- 追加: スマレジ実績 ID は EF の POST 後に入る（それまでは 'req:<申請id>' を仮の一意キーに）。ロック付き＝翌朝の同期で消えない
      insert into labor_cost_daily (user_id, store_id, work_date, clock_in, clock_out, worked_minutes, tardy, early_leaving, smaregi_estimate_cost,
          smaregi_shift_result_id, source, break_start_1, break_end_1, break_start_2, break_end_2, break_minutes, manual_fixed_at, manual_fixed_by)
      values (r.user_id, r.store_id, r.work_date, r.clock_in, r.clock_out, v_min, false, false, null,
          'req:' || r.id, 'form', r.break_start_1, r.break_end_1, r.break_start_2, r.break_end_2, r.break_minutes, now(), p_actor)
      returning id into v_new;
    end if;
    insert into attendance_records (user_id, store_id, work_date, clock_in, clock_out, source)
      values (r.user_id, r.store_id, r.work_date, r.clock_in, r.clock_out, 'api')   -- source は check (api/csv) のため api
      on conflict (user_id, work_date) do update set clock_in = excluded.clock_in, clock_out = excluded.clock_out;
    update sf_attendance_requests set status = 'approved', labor_cost_daily_id = v_new, decided_by = p_actor, decided_at = now(),
           decision_note = nullif(trim(coalesce(p_note, '')), ''), applied_at = now(), updated_at = now() where id = r.id;
  else
    update sf_attendance_requests set status = 'rejected', decided_by = p_actor, decided_at = now(),
           decision_note = nullif(trim(coalesce(p_note, '')), ''), updated_at = now() where id = r.id;
  end if;
  return jsonb_build_object('ok', true, 'request_id', r.id, 'kind', r.kind, 'approved', p_approve, 'summary', sf_attendance_request_summary(r), 'actor_name', v_name,
    'reason', r.reason, 'requested_by_name', (select name from users where id = r.requested_by), 'requested_by', r.requested_by,
    'approval_notification_ids', to_jsonb(r.approval_notification_ids), 'notice_notification_ids', to_jsonb(r.notice_notification_ids));
end $$;
revoke all on function public.sf_attendance_request_decide(uuid, uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_decide(uuid, uuid, boolean, text, text) to service_role;

-- 3) 休憩の自動補完の反映
create or replace function attendance_break_autofill_finish(p_id uuid, p_status text, p_reason text default null, p_response jsonb default null, p_duty_minute numeric default null, p_cost numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a attendance_break_autofills%rowtype; l labor_cost_daily%rowtype;
begin
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  if p_status not in ('synced', 'error', 'conflict', 'skipped') then raise exception '不正な状態です'; end if;
  select * into a from attendance_break_autofills where id = p_id for update;
  if a.id is null then raise exception '履歴が見つかりません'; end if;
  if a.status <> 'syncing' then return jsonb_build_object('ok', false, 'reason', 'not_syncing', 'status', a.status); end if;
  if p_status = 'synced' then
    select * into l from labor_cost_daily where id = a.labor_cost_daily_id for update;
    if l.id is null or l.break_start_1 is not null or l.break_end_1 is not null or l.break_start_2 is not null or l.manual_fixed_at is not null
       or l.clock_in is distinct from (a.before ->> 'clock_in')::timestamptz or l.clock_out is distinct from (a.before ->> 'clock_out')::timestamptz then
      -- スマレジには入ったが、そのあいだに管理システム側の勤怠が変わっていた: 管理システムは書き換えない（次の取り込みに任せる）
      update attendance_break_autofills set status = 'conflict', reason = 'hub_changed', smaregi_response = p_response, synced_at = now(), updated_at = now() where id = a.id;
      return jsonb_build_object('ok', true, 'status', 'conflict', 'reason', 'hub_changed');
    end if;
    update labor_cost_daily set break_start_1 = a.est_break_start, break_end_1 = a.est_break_end, break_minutes = a.est_minutes,
           worked_minutes = coalesce(p_duty_minute, worked_minutes - a.est_minutes), smaregi_estimate_cost = coalesce(p_cost, smaregi_estimate_cost), updated_at = now()
     where id = l.id;
  end if;
  update attendance_break_autofills set status = p_status, reason = p_reason, smaregi_response = p_response, synced_at = case when p_status = 'synced' then now() else synced_at end, updated_at = now() where id = a.id;
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;
revoke all on function attendance_break_autofill_finish(uuid, text, text, jsonb, numeric, numeric) from public, anon, authenticated;
grant execute on function attendance_break_autofill_finish(uuid, text, text, jsonb, numeric, numeric) to service_role;
