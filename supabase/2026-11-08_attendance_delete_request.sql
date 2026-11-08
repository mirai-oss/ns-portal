-- =============================================================
-- 2026-11-08 勤怠確認アラートに「🗑 打刻を消す」（本人が出勤していなかった等）
-- ユーザー指示: 「修正後の時間を入れなくていい打刻削除ボタン。理由は必ず入れる。押したら必ず承認へ飛び、承認を押したら打刻が削除される」
--   流れ: Slack の 🗑 → 理由モーダル → RPC sf_attendance_delete_request（status=fix_requested・request_kind='delete'）→ マスター DM の ✅/❌
--         → RPC sf_attendance_fix_decide（承認: 管理システムの labor_cost_daily と attendance_records を削除）→ EF smaregi-attendance-fix（スマレジの勤務実績を DELETE）
--   削除前の行は alerts の deleted_* に控える（スマレジ削除と履歴のため）。labor_cost_daily の FK は CASCADE→SET NULL に変更（削除してもアラート行を残す）
-- =============================================================

-- 1) 列
alter table public.sf_attendance_alerts
  add column if not exists request_kind text not null default 'fix',
  add column if not exists deleted_shift_result_id text,     -- 削除した行の smaregi_shift_result_id（スマレジ側の削除に使う。'sdm155v1:123' 形式あり）
  add column if not exists deleted_smaregi_staff_id text,
  add column if not exists deleted_source text,
  add column if not exists deleted_labor jsonb;               -- 削除した labor_cost_daily の行の写し
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'sf_attendance_alerts_request_kind_check') then
    alter table public.sf_attendance_alerts add constraint sf_attendance_alerts_request_kind_check check (request_kind in ('fix', 'delete'));
  end if;
end $$;
comment on column public.sf_attendance_alerts.request_kind is '店長の申請の種類: fix=時刻の修正 / delete=打刻の削除（2026-11-08）';

-- 2) FK: 削除してもアラート行が消えないように（CASCADE → SET NULL。列も NULL 可に。rollback テストで not null 違反を検出 2026-11-08）
alter table public.sf_attendance_alerts alter column labor_cost_daily_id drop not null;
alter table public.sf_attendance_alerts drop constraint if exists sf_attendance_alerts_labor_cost_daily_id_fkey;
alter table public.sf_attendance_alerts add constraint sf_attendance_alerts_labor_cost_daily_id_fkey
  foreign key (labor_cost_daily_id) references public.labor_cost_daily(id) on delete set null;

-- 3) 削除の申請（店長・チーム長・本部・社長・マスター。権限は fix_request と同じ）
create or replace function public.sf_attendance_delete_request(p_alert_id uuid, p_actor uuid, p_reason text, p_via text default 'slack')
returns jsonb language plpgsql security definer set search_path = public as $$
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
end $$;
revoke all on function public.sf_attendance_delete_request(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_delete_request(uuid, uuid, text, text) to service_role;

-- 4) 承認（既存の sf_attendance_fix_decide に request_kind='delete' の分岐を追加。fix の処理は 2026-11-07_attendance_breaks.sql と同一）
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
