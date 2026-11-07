-- =============================================================
-- 勤怠の追加・修正申請フォーム（2026-11-07・ユーザー指示「Slack から勤怠修正できるように。管理システムの申請 URL」）
-- 状態: ★ 未適用 ★（dry-run 済み・rollback 内で RPC 検証済み）
-- 流れ: ポータルの kintai.html（ログイン必須）→ EF attendance-request（JWT で申請者を特定）→ RPC sf_attendance_request_submit
--       → マスターの Slack DM に承認依頼 [承認][却下] → slack-interact → RPC sf_attendance_request_decide
--       → 承認: ハブ labor_cost_daily / attendance_records に反映（修正=更新・追加=新規行）→ EF smaregi-attendance-fix がスマレジへ（修正=PUT・追加=POST）
-- 権限: 申請＝その店舗を管理できる人（sf_can_manage と同じ規則）または本人。承認＝マスターのみ。
-- =============================================================
create table if not exists sf_attendance_requests (
  id                  uuid primary key default gen_random_uuid(),
  kind                text not null check (kind in ('add','fix')),       -- 勤怠追加 / 勤怠修正
  store_id            uuid not null references stores(id),
  user_id             uuid not null references users(id),                 -- 対象スタッフ
  work_date           date not null,
  labor_cost_daily_id uuid references labor_cost_daily(id) on delete set null,   -- fix のとき元の行
  before              jsonb,                                              -- fix のとき元の値
  clock_in            timestamptz not null,
  clock_out           timestamptz not null,
  break_start_1       timestamptz, break_end_1 timestamptz, break_start_2 timestamptz, break_end_2 timestamptz,
  break_minutes       numeric not null default 0,
  reason              text not null,
  status              text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  requested_by        uuid not null references users(id),
  requested_via       text not null default 'form',
  requested_at        timestamptz not null default now(),
  decided_by          uuid references users(id),
  decided_at          timestamptz,
  decision_note       text,
  applied_at          timestamptz,
  approval_notification_ids uuid[] not null default '{}',
  notice_notification_ids   uuid[] not null default '{}',                 -- 勤怠確認チャンネルへの「申請がありました」
  smaregi_sync_status text check (smaregi_sync_status in ('pending','synced','failed','skipped')),
  smaregi_synced_at   timestamptz,
  smaregi_error       text,
  smaregi_response    jsonb,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists sf_attendance_requests_status_idx on sf_attendance_requests (status, requested_at desc);
create index if not exists sf_attendance_requests_user_idx on sf_attendance_requests (user_id, work_date);
comment on table sf_attendance_requests is '勤怠の追加・修正申請（フォーム）。状態遷移は RPC のみ。承認でハブ反映＋スマレジ書き戻し';

alter table sf_attendance_requests enable row level security;
drop policy if exists sf_attendance_requests_read on sf_attendance_requests;
create policy sf_attendance_requests_read on sf_attendance_requests for select using (
  auth.uid() is not null and (requested_by = auth.uid() or user_id = auth.uid() or sf_can_manage(store_id))
);

-- フォーム用: その店舗の従業員（ログインユーザーが呼ぶ。店舗を管理できる人か、その店舗の所属者だけ）
create or replace function public.sf_attendance_form_staff(p_store_id uuid)
returns table (id uuid, name text, role text) language sql stable security definer set search_path = public as $$
  select u.id, u.name, u.role
  from users u join user_stores us on us.user_id = u.id
  where us.store_id = p_store_id and u.is_active
    and (sf_can_manage(p_store_id) or exists (select 1 from user_stores x where x.user_id = auth.uid() and x.store_id = p_store_id))
  order by u.name;
$$;
grant execute on function public.sf_attendance_form_staff(uuid) to authenticated;

create or replace function public.sf_attendance_request_summary(r sf_attendance_requests)
returns text language sql stable set search_path = public as $$
  select format('%s　%s（%s）　%s　%s　%s−%s（%s時間%s分・%s）',
    case r.kind when 'add' then '勤怠追加' else '勤怠修正' end,
    to_char(r.work_date, 'FMMM/FMDD'),
    (array['日','月','火','水','木','金','土'])[extract(dow from r.work_date)::int + 1],
    (select name from stores where id = r.store_id),
    (select name from users where id = r.user_id),
    to_char(r.clock_in at time zone 'Asia/Tokyo', 'HH24:MI'),
    case when (r.clock_out at time zone 'Asia/Tokyo')::date > (r.clock_in at time zone 'Asia/Tokyo')::date then '翌' else '' end
      || to_char(r.clock_out at time zone 'Asia/Tokyo', 'HH24:MI'),
    floor((extract(epoch from (r.clock_out - r.clock_in)) / 60 - r.break_minutes) / 60)::int,
    ((extract(epoch from (r.clock_out - r.clock_in)) / 60 - r.break_minutes)::int % 60),
    sf_attendance_break_text(r.break_start_1, r.break_end_1, r.break_start_2, r.break_end_2));
$$;

-- 申請（EF attendance-request が service_role で呼ぶ。p_actor=申請者）
create or replace function public.sf_attendance_request_submit(
  p_actor uuid, p_kind text, p_store_id uuid, p_user_id uuid, p_work_date date,
  p_clock_in timestamptz, p_clock_out timestamptz, p_reason text,
  p_break_start_1 timestamptz default null, p_break_end_1 timestamptz default null,
  p_break_start_2 timestamptz default null, p_break_end_2 timestamptz default null, p_via text default 'form')
returns jsonb language plpgsql security definer set search_path = public as $$
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
end $$;
revoke all on function public.sf_attendance_request_submit(uuid, text, uuid, uuid, date, timestamptz, timestamptz, text, timestamptz, timestamptz, timestamptz, timestamptz, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_submit(uuid, text, uuid, uuid, date, timestamptz, timestamptz, text, timestamptz, timestamptz, timestamptz, timestamptz, text) to service_role;

-- 承認 / 却下（マスターのみ）。承認でハブに反映（修正=更新＋ロック、追加=新規行＋ロック）。スマレジ側は EF が行う
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
