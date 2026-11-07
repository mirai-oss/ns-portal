-- =============================================================
-- 勤怠確認ボタン③: 休憩時間を取込・表示・修正入力・反映・スマレジ書き戻しに通す（2026-11-07・ユーザー指示）
-- 状態: ★ 未適用 ★（dry-run 済み・rollback 内で RPC 検証済み）
-- 変更点:
--   labor_cost_daily: break_start_1/break_end_1/break_start_2/break_end_2（スマレジ breakStartTime1〜）＋ break_minutes。手修正ロックの対象に追加
--   sf_attendance_alerts: 検知時の休憩 4 列＋ 申請の休憩 4 列（proposed_break_*）
--   sf_attendance_alert_summary: 「（24時間0分・休憩 12:00−13:00）」の形
--   sf_attendance_fix_request: 休憩 4 引数を追加（旧シグネチャは drop。検証: 対になっている・出勤〜退勤の内側・終了>開始・休憩2は休憩1より後・合計 4h 以内）
--   sf_attendance_fix_decide: 承認で休憩も反映。worked_minutes＝(退勤−出勤)−休憩
-- =============================================================

-- 1. 列
alter table labor_cost_daily
  add column if not exists break_start_1 timestamptz,
  add column if not exists break_end_1   timestamptz,
  add column if not exists break_start_2 timestamptz,
  add column if not exists break_end_2   timestamptz,
  add column if not exists break_minutes numeric;
comment on column labor_cost_daily.break_minutes is '休憩合計（分）。同期がスマレジ breakStartTime1〜breakEndTime2 から計算。承認反映時は申請値';

alter table sf_attendance_alerts
  add column if not exists break_start_1 timestamptz,
  add column if not exists break_end_1   timestamptz,
  add column if not exists break_start_2 timestamptz,
  add column if not exists break_end_2   timestamptz,
  add column if not exists proposed_break_start_1 timestamptz,
  add column if not exists proposed_break_end_1   timestamptz,
  add column if not exists proposed_break_start_2 timestamptz,
  add column if not exists proposed_break_end_2   timestamptz;

-- 2. 手修正ロック（休憩列も守る）
create or replace function public.labor_cost_daily_keep_manual_fix()
returns trigger language plpgsql as $$
begin
  if old.manual_fixed_at is not null and new.manual_fixed_at is not distinct from old.manual_fixed_at then
    new.clock_in := old.clock_in;
    new.clock_out := old.clock_out;
    new.worked_minutes := old.worked_minutes;
    new.smaregi_estimate_cost := old.smaregi_estimate_cost;
    new.tardy := old.tardy;
    new.early_leaving := old.early_leaving;
    new.break_start_1 := old.break_start_1; new.break_end_1 := old.break_end_1;
    new.break_start_2 := old.break_start_2; new.break_end_2 := old.break_end_2;
    new.break_minutes := old.break_minutes;
  end if;
  return new;
end $$;

-- 3. 休憩の表示用（例: 休憩 12:00−13:00・15:00−15:30 ／ 休憩なし）
create or replace function public.sf_attendance_break_text(b1s timestamptz, b1e timestamptz, b2s timestamptz, b2e timestamptz)
returns text language sql immutable as $$
  select case when b1s is null and b2s is null then '休憩なし'
    else '休憩 ' || concat_ws('・',
      case when b1s is not null then to_char(b1s at time zone 'Asia/Tokyo', 'HH24:MI') || '−' || to_char(b1e at time zone 'Asia/Tokyo', 'HH24:MI') end,
      case when b2s is not null then to_char(b2s at time zone 'Asia/Tokyo', 'HH24:MI') || '−' || to_char(b2e at time zone 'Asia/Tokyo', 'HH24:MI') end) end
$$;

create or replace function public.sf_attendance_alert_summary(p_alert sf_attendance_alerts)
returns text language sql stable set search_path = public as $$
  select format('%s（%s）　%s　%s　%s−%s（%s・%s）',
    to_char(p_alert.work_date, 'FMMM/FMDD'),
    (array['日','月','火','水','木','金','土'])[extract(dow from p_alert.work_date)::int + 1],
    (select name from stores where id = p_alert.store_id),
    (select name from users where id = p_alert.user_id),
    to_char(p_alert.clock_in at time zone 'Asia/Tokyo', 'HH24:MI'),
    case when (p_alert.clock_out at time zone 'Asia/Tokyo')::date > p_alert.work_date then '翌' else '' end
      || to_char(p_alert.clock_out at time zone 'Asia/Tokyo', 'HH24:MI'),
    (floor(coalesce(p_alert.worked_minutes,0) / 60))::int || '時間' || (coalesce(p_alert.worked_minutes,0)::int % 60) || '分',
    sf_attendance_break_text(p_alert.break_start_1, p_alert.break_end_1, p_alert.break_start_2, p_alert.break_end_2));
$$;

-- 4. 修正申請（休憩つき）。旧シグネチャは削除（名前付き引数で呼ぶ EF が曖昧にならないように）
drop function if exists public.sf_attendance_fix_request(uuid, uuid, timestamptz, timestamptz, text, text);
create or replace function public.sf_attendance_fix_request(
  p_alert_id uuid, p_actor uuid, p_clock_in timestamptz, p_clock_out timestamptz, p_reason text, p_via text default 'slack',
  p_break_start_1 timestamptz default null, p_break_end_1 timestamptz default null,
  p_break_start_2 timestamptz default null, p_break_end_2 timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a sf_attendance_alerts%rowtype; v_name text; v_prev text; v_min numeric; v_break numeric := 0;
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
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この店舗の勤怠を修正する権限がありません');
  end if;
  if p_clock_in is null or p_clock_out is null or p_clock_out <= p_clock_in then
    return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '退勤は出勤より後の時刻にしてください');
  end if;
  v_min := extract(epoch from (p_clock_out - p_clock_in)) / 60;
  if v_min > 24 * 60 then return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '勤務は 24 時間以内にしてください'); end if;
  if (p_clock_in at time zone 'Asia/Tokyo')::date not between a.work_date - 1 and a.work_date + 1 then
    return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '出勤日が勤務日と離れすぎています');
  end if;
  -- 休憩の検査
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
    return jsonb_build_object('ok', false, 'code', 'invalid_reason', 'message', '修正理由を 300 字以内で入れてください');
  end if;
  update sf_attendance_alerts
     set status = 'fix_requested', proposed_clock_in = p_clock_in, proposed_clock_out = p_clock_out, fix_reason = trim(p_reason),
         proposed_break_start_1 = p_break_start_1, proposed_break_end_1 = p_break_end_1,
         proposed_break_start_2 = p_break_start_2, proposed_break_end_2 = p_break_end_2,
         requested_by = p_actor, requested_at = now(), updated_at = now()
   where id = a.id;
  return jsonb_build_object('ok', true, 'alert_id', a.id, 'summary', sf_attendance_alert_summary(a), 'actor_name', v_name,
    'proposed', format('%s−%s（%s時間%s分・%s）',
      to_char(p_clock_in at time zone 'Asia/Tokyo', 'HH24:MI'),
      case when (p_clock_out at time zone 'Asia/Tokyo')::date > (p_clock_in at time zone 'Asia/Tokyo')::date then '翌' else '' end
        || to_char(p_clock_out at time zone 'Asia/Tokyo', 'HH24:MI'),
      floor((v_min - v_break) / 60)::int, ((v_min - v_break)::int % 60),
      sf_attendance_break_text(p_break_start_1, p_break_end_1, p_break_start_2, p_break_end_2)),
    'reason', trim(p_reason), 'notification_ids', to_jsonb(a.notification_ids));
end $$;
revoke all on function public.sf_attendance_fix_request(uuid, uuid, timestamptz, timestamptz, text, text, timestamptz, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.sf_attendance_fix_request(uuid, uuid, timestamptz, timestamptz, text, text, timestamptz, timestamptz, timestamptz, timestamptz) to service_role;

-- 5. 承認（休憩も反映。worked_minutes＝(退勤−出勤)−休憩）
create or replace function public.sf_attendance_fix_decide(p_alert_id uuid, p_actor uuid, p_approve boolean, p_note text default null, p_via text default 'slack')
returns jsonb language plpgsql security definer set search_path = public as $$
declare a sf_attendance_alerts%rowtype; v_name text; v_master boolean; v_prev text; v_min numeric; v_break numeric; l labor_cost_daily%rowtype; v_est numeric;
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

  if p_approve then
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
  return jsonb_build_object('ok', true, 'alert_id', a.id, 'approved', p_approve, 'summary', sf_attendance_alert_summary(a), 'actor_name', v_name,
    'proposed', format('%s−%s（%s）',
      to_char(a.proposed_clock_in at time zone 'Asia/Tokyo', 'HH24:MI'),
      case when (a.proposed_clock_out at time zone 'Asia/Tokyo')::date > (a.proposed_clock_in at time zone 'Asia/Tokyo')::date then '翌' else '' end
        || to_char(a.proposed_clock_out at time zone 'Asia/Tokyo', 'HH24:MI'),
      sf_attendance_break_text(a.proposed_break_start_1, a.proposed_break_end_1, a.proposed_break_start_2, a.proposed_break_end_2)),
    'reason', a.fix_reason, 'note', nullif(trim(coalesce(p_note, '')), ''),
    'requested_by_name', (select name from users where id = a.requested_by),
    'notification_ids', to_jsonb(a.notification_ids), 'approval_notification_ids', to_jsonb(a.approval_notification_ids));
end $$;
