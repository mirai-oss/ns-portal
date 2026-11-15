-- =============================================================
-- 勤怠修正申請の改善・第 2 弾: 店舗別の一次承認者 ＋ 2 段階承認 ＋ 差戻し・却下（理由必須）＋ 状態（2026-11-15 下書き・★ 本番未適用 ★）
--   設計: ob22/設計_勤怠修正申請_改善.md（§3〜§7）
--   前提: 2026-12-09_attendance_request_thread.sql（第 1 弾）が適用済みであること
--   戻し方: 2026-12-10_attendance_request_two_stage_rollback.sql
--
--   この SQL も「足すだけ」。今ある関数（sf_attendance_request_submit / _decide ほか）は作り替えない。
--   適用しただけでは何も変わらない: スイッチ app_settings.attendance_request_flow.two_stage が false のあいだ、
--   新しい申請には flow が入らず（null）、今までの 1 段階（マスターの承認）のまま動く。
--   一次承認者の表は「枠だけ」。行は 1 つも入れない（設定は社長の確認のあと、sf_attendance_first_approver_set で）。
--
--   流れ（スイッチ ON のあとに出た申請だけ）:
--     申請 → 一次承認待ち（その店舗の一次承認者）→ 最終承認待ち（社長）→ 承認済み（ここで初めて勤怠が書き換わる）→ スマレジへ反映
--     ・一次承認者が未設定 → 確認待ち（hold）。設定されたら動き出す
--     ・一次承認者 本人の申請・本人の勤怠 → 一次承認を省略して、最終承認待ちから
--     ・差戻し → 出し直し（前の承認を消して、一次承認からやり直し）／却下（理由必須）
--     ・承認の直前に、元データが申請時点から変わっていたら、承認せずに差戻しにする
--   守り: 2 段階の申請は、下の関数（_act / _resubmit / _message / _first_approver_set）を通らないと、状態・中身を変えられない
--         （今ある 1 段階の承認の関数 sf_attendance_request_decide を直接呼んでも、DB のトリガーが止める）。
-- =============================================================

-- ============ 1. 店舗別の一次承認者（枠だけ。行は入れない） ============
create table if not exists sf_attendance_first_approvers (
  store_id         uuid primary key references stores(id),
  approver_user_id uuid not null references users(id),     -- 従業員 ID で持つ（氏名では持たない）
  note             text,
  updated_at       timestamptz not null default now(),
  updated_by       uuid references users(id)
);
comment on table sf_attendance_first_approvers is '勤怠修正申請の一次承認者（店舗 ID → 従業員 ID）。行が無い店舗＝未設定＝申請は「確認待ち」。変更は sf_attendance_first_approver_set（社長だけ）';
create table if not exists sf_attendance_first_approver_changes (
  id          uuid primary key default gen_random_uuid(),
  store_id    uuid not null references stores(id),
  old_user_id uuid references users(id),
  new_user_id uuid references users(id),
  changed_by  uuid references users(id),
  changed_at  timestamptz not null default now(),
  note        text
);
alter table sf_attendance_first_approvers enable row level security;
alter table sf_attendance_first_approver_changes enable row level security;
drop policy if exists sf_attendance_first_approvers_read on sf_attendance_first_approvers;
create policy sf_attendance_first_approvers_read on sf_attendance_first_approvers for select using (auth.uid() is not null);
drop policy if exists sf_attendance_first_approver_changes_read on sf_attendance_first_approver_changes;
create policy sf_attendance_first_approver_changes_read on sf_attendance_first_approver_changes for select using (auth.uid() is not null and sf_can_manage(store_id));
revoke insert, update, delete, truncate on sf_attendance_first_approvers from anon, authenticated;
revoke insert, update, delete, truncate on sf_attendance_first_approver_changes from anon, authenticated;

-- ============ 2. 申請の行に足す列（今ある行は flow=null＝今までの 1 段階のまま） ============
alter table sf_attendance_requests
  add column if not exists flow               text check (flow in ('two_stage')),
  add column if not exists stage              text check (stage in ('first_wait', 'asking', 'returned', 'final_wait', 'hold')),
  add column if not exists first_approver_id  uuid references users(id),    -- 申請時点で決まった一次承認者（進行中は変わらない）
  add column if not exists first_skipped      boolean not null default false,   -- 一次承認者 本人の申請・本人の勤怠＝一次承認を省略
  add column if not exists first_decided_by   uuid references users(id),
  add column if not exists first_decided_at   timestamptz,
  add column if not exists first_note         text,
  add column if not exists final_requested_at timestamptz,                  -- 社長へ最終承認を依頼した時刻
  add column if not exists returned_by        uuid references users(id),    -- 差戻しをした人（元データの変化による自動の差戻しは null）
  add column if not exists returned_at        timestamptz,
  add column if not exists return_note        text,
  add column if not exists round              integer not null default 1,   -- 出し直しのたびに 1 増える
  add column if not exists sync_claimed_at    timestamptz;                  -- スマレジへ送る前の「いま送ります」の札
comment on column sf_attendance_requests.flow is 'null＝今までの 1 段階（マスターの承認）／two_stage＝店舗別の一次承認 → 社長の最終承認';
comment on column sf_attendance_requests.stage is '2 段階の承認待ちのあいだの段階: first_wait 一次承認待ち／asking 本人確認中／returned 差戻し／final_wait 最終承認待ち／hold 確認待ち（一次承認者が未設定）';

-- ============ 3. 状態の言葉（画面と Slack で同じ 9 つ＋今までの承認待ち） ============
--   first_wait / asking / returned / final_wait / hold / pending（今までの承認待ち）/ sync_wait（承認済み・スマレジ反映待ち）/ synced / sync_error / rejected / cancelled
create or replace function public.sf_attendance_request_state(r sf_attendance_requests) returns text
language sql stable set search_path = public as $$
  select case
    when r.status = 'pending' and r.flow = 'two_stage' and r.stage is not null then r.stage
    when r.status = 'pending' then 'pending'
    when r.status = 'approved' and r.smaregi_sync_status = 'failed' then 'sync_error'
    when r.status = 'approved' and r.smaregi_sync_status in ('synced', 'skipped') then 'synced'
    when r.status = 'approved' then 'sync_wait'
    else r.status end;
$$;

-- ============ 4. 一次承認者の決め方（店舗 ID だけで決める。未設定・退職なら hold） ============
create or replace function public.sf_attendance_request_route(p_store uuid, p_requested_by uuid, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ap uuid;
begin
  select a.approver_user_id into v_ap
    from sf_attendance_first_approvers a join users u on u.id = a.approver_user_id
   where a.store_id = p_store and u.is_active and u.deactivated_at is null;
  if v_ap is null then
    return jsonb_build_object('stage', 'hold', 'first_approver_id', null, 'first_skipped', false);
  end if;
  if coalesce(v_ap = p_requested_by, false) or coalesce(v_ap = p_user, false) then   -- 一次承認者 本人の申請・本人の勤怠 → 省略して社長へ（自己承認をさせない）
    return jsonb_build_object('stage', 'final_wait', 'first_approver_id', v_ap, 'first_skipped', true);
  end if;
  return jsonb_build_object('stage', 'first_wait', 'first_approver_id', v_ap, 'first_skipped', false);
end $$;
revoke all on function public.sf_attendance_request_route(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_route(uuid, uuid, uuid) to service_role;

-- ============ 5. 新しい申請に、流れと最初の段階を入れる（スイッチが ON のときだけ） ============
create or replace function public.sf_attendance_requests_flow_init() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_set jsonb; v_route jsonb;
begin
  select value into v_set from app_settings where key = 'attendance_request_flow';
  -- JSON の true とはっきり書いてあるときだけ ON（文字の "true" などは OFF 扱い。読めない値で申請を止めない）
  if coalesce((v_set -> 'thread') = 'true'::jsonb, false) and coalesce((v_set -> 'two_stage') = 'true'::jsonb, false)
     and new.flow is null and new.status = 'pending' then
    v_route := sf_attendance_request_route(new.store_id, new.requested_by, new.user_id);
    new.flow := 'two_stage';
    new.stage := v_route ->> 'stage';
    new.first_approver_id := nullif(v_route ->> 'first_approver_id', '')::uuid;
    new.first_skipped := coalesce((v_route ->> 'first_skipped')::boolean, false);
    if new.stage = 'final_wait' then new.final_requested_at := now(); end if;
  end if;
  return new;
end $$;
drop trigger if exists sf_attendance_requests_b_flow_bi on sf_attendance_requests;
create trigger sf_attendance_requests_b_flow_bi before insert on sf_attendance_requests
  for each row execute function public.sf_attendance_requests_flow_init();

create or replace function public.sf_attendance_requests_flow_routed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.flow is not distinct from 'two_stage' then
    begin
      insert into sf_attendance_request_events(request_id, actor, action, via, data)
      values (new.id, null, 'routed', 'system', jsonb_build_object('stage', new.stage, 'first_approver_id', new.first_approver_id, 'first_skipped', new.first_skipped));
    exception when others then
      raise warning 'sf_attendance_requests_flow_routed: %', sqlerrm;
    end;
  end if;
  return null;
end $$;
drop trigger if exists sf_attendance_requests_flow_ai on sf_attendance_requests;
create trigger sf_attendance_requests_flow_ai after insert on sf_attendance_requests
  for each row execute function public.sf_attendance_requests_flow_routed();

-- ============ 6. 守り: 2 段階の申請は、決められた関数からしか 状態・中身を変えられない ============
--   決められた関数は、取引の中だけの印 sf_att.op に申請の id を入れてから行を更新する。印が無い更新は、ここで止まる。
--   止めない列: Slack の台帳 id・リマインドの印・スマレジの結果（smaregi_*）・updated_at など（状態と中身ではないもの）
create or replace function public.sf_attendance_requests_flow_guard() returns trigger
language plpgsql set search_path = public as $$
declare v_op text := coalesce(current_setting('sf_att.op', true), '');
begin
  if v_op = old.id::text then return new; end if;
  if old.flow is distinct from 'two_stage' then
    if new.flow is not distinct from 'two_stage' then
      raise exception '今までの形の申請を、2 段階承認の申請に書き換えることはできません';
    end if;
    return new;   -- 今までの 1 段階の申請は、今までどおり
  end if;
  if new.status is distinct from old.status or new.flow is distinct from old.flow or new.stage is distinct from old.stage
     or new.first_approver_id is distinct from old.first_approver_id or new.first_skipped is distinct from old.first_skipped
     or new.first_decided_by is distinct from old.first_decided_by or new.first_decided_at is distinct from old.first_decided_at
     or new.decided_by is distinct from old.decided_by or new.round is distinct from old.round
     or new.kind is distinct from old.kind or new.store_id is distinct from old.store_id or new.user_id is distinct from old.user_id or new.work_date is distinct from old.work_date
     or new.clock_in is distinct from old.clock_in or new.clock_out is distinct from old.clock_out
     or new.break_start_1 is distinct from old.break_start_1 or new.break_end_1 is distinct from old.break_end_1
     or new.break_start_2 is distinct from old.break_start_2 or new.break_end_2 is distinct from old.break_end_2
     or new.before is distinct from old.before then
    raise exception '2 段階承認の申請は、決められた操作（一次承認・最終承認・差戻し・却下・出し直し）からだけ変えられます';
  end if;
  return new;
end $$;
drop trigger if exists sf_attendance_requests_flow_guard_bu on sf_attendance_requests;
create trigger sf_attendance_requests_flow_guard_bu before update on sf_attendance_requests
  for each row execute function public.sf_attendance_requests_flow_guard();

-- ============ 7. 時刻の検査（出し直し用。申請の関数 sf_attendance_request_submit と同じ決まり） ============
create or replace function public.sf_attendance_times_check(p_work_date date, p_clock_in timestamptz, p_clock_out timestamptz,
  p_break_start_1 timestamptz, p_break_end_1 timestamptz, p_break_start_2 timestamptz, p_break_end_2 timestamptz) returns jsonb
language plpgsql stable set search_path = public as $$
declare v_min numeric; v_break numeric := 0;
begin
  if p_clock_in is null or p_clock_out is null or p_clock_out <= p_clock_in then
    return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '退勤は出勤より後の時刻にしてください');
  end if;
  v_min := extract(epoch from (p_clock_out - p_clock_in)) / 60;
  if v_min > 24 * 60 then return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '勤務は 24 時間以内にしてください'); end if;
  if (p_clock_in at time zone 'Asia/Tokyo')::date not between p_work_date - 1 and p_work_date + 1 then
    return jsonb_build_object('ok', false, 'code', 'invalid_time', 'message', '出勤日が勤務日と離れすぎています');
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
  return jsonb_build_object('ok', true, 'break_minutes', round(v_break));
end $$;
revoke all on function public.sf_attendance_times_check(date, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.sf_attendance_times_check(date, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz, timestamptz) to service_role;

-- ============ 8. 操作（一次承認・本人確認中・差戻し・却下・最終承認）。権限と状態の検査はここ 1 か所 ============
--   p_action: first_approve / ask / return / reject / final_approve / cancel（取り下げ）
--   一次承認の段階（first_wait・asking）: その申請の一次承認者（first_approver_id）本人だけ
--   最終承認の段階（final_wait）        : 社長（役割 CEO）本人だけ。マスター権限だけの人は不可
--   差戻し・却下は理由が必須。承認の直前に、元データが申請時点から変わっていたら、承認せずに差戻しにする（code=source_changed）
--   最終承認のときだけ、今ある承認の関数（sf_attendance_request_decide）を呼んで、勤怠（labor_cost_daily・attendance_records）を書き換える
create or replace function public.sf_attendance_request_act(p_request_id uuid, p_actor uuid, p_action text, p_note text default null, p_via text default 'slack')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c_changed constant text := '申請のあとに、元の打刻が変わりました。内容を確かめて、出し直してください。';
  r sf_attendance_requests%rowtype; v_name text; v_role text; v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_first boolean; v_final boolean; v_src jsonb; v_res jsonb; v_state text;
begin
  select name, role into v_name, v_role from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  if p_action is null or p_action not in ('first_approve', 'ask', 'return', 'reject', 'final_approve', 'cancel') then
    return jsonb_build_object('ok', false, 'code', 'invalid', 'message', 'この操作はできません');
  end if;
  select * into r from sf_attendance_requests where id = p_request_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この申請は見つかりません'); end if;
  if r.flow is distinct from 'two_stage' then
    return jsonb_build_object('ok', false, 'code', 'not_two_stage', 'message', 'この申請は 2 段階承認の対象ではありません（今までの承認の操作を使ってください）');
  end if;
  if r.status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'already', 'message', 'この申請はすでに処理されています', 'state', sf_attendance_request_state(r));
  end if;
  if p_action = 'cancel' then
    -- 取り下げ: 申請した人は、承認待ちのあいだならいつでも。確認待ち・差戻しのまま止まっている申請は、社長も取り下げできる（同じ人・同じ日の出し直しを止めないため）
    if not (coalesce(p_actor = r.requested_by, false) or (coalesce(v_role, '') = 'CEO' and coalesce(r.stage in ('hold', 'returned'), false))) then
      return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', '取り下げできるのは、申請した人だけです（確認待ち・差戻しのままの申請は、社長も取り下げできます）');
    end if;
    perform set_config('sf_att.op', r.id::text, true);
    update sf_attendance_requests set status = 'cancelled', decided_by = p_actor, decided_at = now(), decision_note = v_note, updated_at = now() where id = r.id;
    perform set_config('sf_att.op', '', true);
    return jsonb_build_object('ok', true, 'request_id', r.id, 'action', p_action, 'state', 'cancelled', 'actor_name', v_name);
  end if;
  v_first := coalesce(r.stage in ('first_wait', 'asking'), false);
  v_final := coalesce(r.stage = 'final_wait', false);
  if (p_action in ('first_approve', 'ask') and not v_first) or (p_action = 'final_approve' and not v_final)
     or (p_action in ('return', 'reject') and not (v_first or v_final)) then
    return jsonb_build_object('ok', false, 'code', 'wrong_stage', 'message', 'いまの状態では、この操作はできません（ほかの人が先に操作したか、段階が違います）', 'state', sf_attendance_request_state(r));
  end if;
  -- 権限（サーバー側の検査。画面や Slack のボタンの出し分けには頼らない）
  if v_first then
    if r.first_approver_id is distinct from p_actor then
      return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'いまは一次承認の段階です。操作できるのは、この申請の一次承認者だけです');
    end if;
    if p_action = 'first_approve' and (coalesce(p_actor = r.requested_by, false) or coalesce(p_actor = r.user_id, false)) then
      return jsonb_build_object('ok', false, 'code', 'self', 'message', '自分が出した申請・自分の勤怠の申請は、自分では承認できません');
    end if;
  else
    if coalesce(v_role, '') <> 'CEO' then
      return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'いまは最終承認の段階です。操作できるのは社長だけです（マスター権限では代行できません）');
    end if;
    if p_action = 'final_approve' and coalesce(p_actor = r.user_id, false) then
      return jsonb_build_object('ok', false, 'code', 'self', 'message', '自分の勤怠の申請は、自分では最終承認できません');
    end if;
    if p_action = 'final_approve' and coalesce(p_actor = r.requested_by, false) and (r.first_decided_by is null or r.first_decided_by = p_actor) then
      return jsonb_build_object('ok', false, 'code', 'self', 'message', '自分が出した申請は、別の人の一次承認が済んでいないと最終承認できません');
    end if;
  end if;
  if p_action in ('return', 'reject') and (v_note is null or length(v_note) > 300) then
    return jsonb_build_object('ok', false, 'code', 'reason_required', 'message', '理由を 300 字以内で入れてください（理由が無いと、差戻し・却下はできません）');
  end if;
  if p_action = 'ask' and r.stage = 'asking' then
    return jsonb_build_object('ok', false, 'code', 'already', 'message', 'すでに「本人確認中」です', 'state', 'asking');
  end if;

  perform set_config('sf_att.op', r.id::text, true);
  if p_action = 'ask' then
    update sf_attendance_requests set stage = 'asking', updated_at = now() where id = r.id;
    insert into sf_attendance_request_events(request_id, actor, action, via, note) values (r.id, p_actor, 'asked', p_via, v_note);
  elsif p_action = 'return' then
    update sf_attendance_requests
       set stage = 'returned', returned_by = p_actor, returned_at = now(), return_note = v_note,
           first_decided_by = null, first_decided_at = null, first_note = null, final_requested_at = null, updated_at = now()
     where id = r.id;
    insert into sf_attendance_request_events(request_id, actor, action, via, note, data)
    values (r.id, p_actor, 'returned', p_via, v_note, jsonb_build_object('from_stage', r.stage, 'round', r.round));
  elsif p_action = 'reject' then
    -- 却下の履歴（rejected）は、第 1 弾のトリガーが残す（操作した人＝decided_by・理由＝decision_note）
    update sf_attendance_requests set status = 'rejected', decided_by = p_actor, decided_at = now(), decision_note = v_note, updated_at = now() where id = r.id;
  else
    v_src := sf_attendance_request_source_check(r.id);
    if coalesce(v_src ->> 'state', '') <> 'same' then
      -- 元データが申請時点から変わっている: 古い内容のまま承認しない。差戻しにして、出し直し（＝控えの取り直しと一次承認のやり直し）を求める
      update sf_attendance_requests
         set stage = 'returned', returned_by = null, returned_at = now(), return_note = c_changed, source_changed_at = now(), source_change = v_src,
             first_decided_by = null, first_decided_at = null, first_note = null, final_requested_at = null, updated_at = now()
       where id = r.id;
      insert into sf_attendance_request_events(request_id, actor, action, via, note, data)
      values (r.id, null, 'source_changed', 'system', c_changed, jsonb_build_object('found_by', p_actor, 'on', p_action, 'source', v_src));
      perform set_config('sf_att.op', '', true);
      return jsonb_build_object('ok', false, 'code', 'source_changed', 'message', c_changed, 'request_id', r.id, 'state', 'returned');
    end if;
    if p_action = 'first_approve' then
      update sf_attendance_requests
         set stage = 'final_wait', first_decided_by = p_actor, first_decided_at = now(), first_note = v_note, final_requested_at = now(), updated_at = now()
       where id = r.id;
      insert into sf_attendance_request_events(request_id, actor, action, via, note) values (r.id, p_actor, 'first_approved', p_via, v_note);
    else
      -- 最終承認: 今ある承認の関数で勤怠を書き換える（修正＝上書き＋ロック／追加＝新しい行）。ここで初めて勤怠のデータが変わる
      v_res := sf_attendance_request_decide(r.id, p_actor, true, v_note, p_via);
      if coalesce((v_res ->> 'ok')::boolean, false) is not true then
        perform set_config('sf_att.op', '', true);
        return v_res;
      end if;
      update sf_attendance_requests set stage = null, updated_at = now() where id = r.id;
      insert into sf_attendance_request_events(request_id, actor, action, via, note) values (r.id, p_actor, 'final_approved', p_via, v_note);
    end if;
  end if;
  perform set_config('sf_att.op', '', true);
  select sf_attendance_request_state(x) into v_state from sf_attendance_requests x where x.id = r.id;
  return jsonb_build_object('ok', true, 'request_id', r.id, 'action', p_action, 'state', v_state, 'actor_name', v_name);
end $$;
revoke all on function public.sf_attendance_request_act(uuid, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_act(uuid, uuid, text, text, text) to service_role;

-- ============ 9. 出し直し（差戻しのあと）。前の承認を消して、控えを取り直し、一次承認からやり直す ============
create or replace function public.sf_attendance_request_resubmit(p_request_id uuid, p_actor uuid, p_clock_in timestamptz, p_clock_out timestamptz, p_reason text,
  p_break_start_1 timestamptz default null, p_break_end_1 timestamptz default null, p_break_start_2 timestamptz default null, p_break_end_2 timestamptz default null,
  p_via text default 'form')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r sf_attendance_requests%rowtype; l labor_cost_daily%rowtype; v_name text; v_reason text := trim(coalesce(p_reason, ''));
  v_chk jsonb; v_before jsonb; v_meta jsonb; v_route jsonb; v_old jsonb; v_same boolean; v_can boolean; v_state text;
begin
  select name into v_name from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  select * into r from sf_attendance_requests where id = p_request_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この申請は見つかりません'); end if;
  if r.flow is distinct from 'two_stage' or r.status <> 'pending' or r.stage is distinct from 'returned' then
    return jsonb_build_object('ok', false, 'code', 'wrong_stage', 'message', '出し直せるのは、差戻しになっている申請だけです');
  end if;
  v_can := coalesce(p_actor = r.requested_by, false) or coalesce(p_actor = r.user_id, false) or coalesce(sf_can_manage_as(p_actor, r.store_id), false);
  if not v_can then
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この申請を出し直す権限がありません');
  end if;
  v_chk := sf_attendance_times_check(r.work_date, p_clock_in, p_clock_out, p_break_start_1, p_break_end_1, p_break_start_2, p_break_end_2);
  if coalesce((v_chk ->> 'ok')::boolean, false) is not true then return v_chk; end if;
  if length(v_reason) not between 1 and 300 then
    return jsonb_build_object('ok', false, 'code', 'invalid_reason', 'message', '理由を 300 字以内で入れてください');
  end if;
  if r.kind = 'fix' then
    select * into l from labor_cost_daily where id = r.labor_cost_daily_id;
    if not found then
      return jsonb_build_object('ok', false, 'code', 'no_record', 'message', '元の勤怠が無くなっています。この申請は却下にして、「勤怠追加」で出し直してください');
    end if;
    select date_trunc('minute', l.clock_in) is not distinct from date_trunc('minute', p_clock_in)
       and date_trunc('minute', l.clock_out) is not distinct from date_trunc('minute', p_clock_out)
       and date_trunc('minute', l.break_start_1) is not distinct from date_trunc('minute', p_break_start_1)
       and date_trunc('minute', l.break_end_1) is not distinct from date_trunc('minute', p_break_end_1)
       and date_trunc('minute', l.break_start_2) is not distinct from date_trunc('minute', p_break_start_2)
       and date_trunc('minute', l.break_end_2) is not distinct from date_trunc('minute', p_break_end_2)
      into v_same;
    if v_same then
      return jsonb_build_object('ok', false, 'code', 'no_change', 'message', '修正前から変わっていません。直す時刻を入れてから出し直してください');
    end if;
    v_before := jsonb_build_object('clock_in', l.clock_in, 'clock_out', l.clock_out, 'worked_minutes', l.worked_minutes,
      'break_start_1', l.break_start_1, 'break_end_1', l.break_end_1, 'break_start_2', l.break_start_2, 'break_end_2', l.break_end_2, 'break_minutes', l.break_minutes);
    v_meta := jsonb_build_object('exists', true, 'labor_cost_daily_id', l.id, 'smaregi_shift_result_id', l.smaregi_shift_result_id,
      'source', l.source, 'row_updated_at', l.updated_at, 'manual_fixed', l.manual_fixed_at is not null, 'taken_at', now());
  else
    if exists (select 1 from labor_cost_daily where user_id = r.user_id and work_date = r.work_date and store_id = r.store_id) then
      return jsonb_build_object('ok', false, 'code', 'exists', 'message', 'その日の打刻がすでに登録されています。この申請は却下にして、「勤怠修正」で出し直してください');
    end if;
    v_before := null;
    v_meta := jsonb_build_object('exists', false, 'taken_at', now());
  end if;
  v_route := sf_attendance_request_route(r.store_id, r.requested_by, r.user_id);
  v_old := jsonb_build_object('clock_in', r.clock_in, 'clock_out', r.clock_out, 'break_start_1', r.break_start_1, 'break_end_1', r.break_end_1,
                              'break_start_2', r.break_start_2, 'break_end_2', r.break_end_2, 'reason', r.reason);
  perform set_config('sf_att.op', r.id::text, true);
  update sf_attendance_requests
     set clock_in = p_clock_in, clock_out = p_clock_out, break_start_1 = p_break_start_1, break_end_1 = p_break_end_1,
         break_start_2 = p_break_start_2, break_end_2 = p_break_end_2, break_minutes = (v_chk ->> 'break_minutes')::numeric, reason = v_reason,
         before = v_before, before_meta = v_meta, source_changed_at = null, source_change = null,
         round = r.round + 1, stage = v_route ->> 'stage', first_approver_id = nullif(v_route ->> 'first_approver_id', '')::uuid,
         first_skipped = coalesce((v_route ->> 'first_skipped')::boolean, false),
         first_decided_by = null, first_decided_at = null, first_note = null,
         final_requested_at = case when v_route ->> 'stage' = 'final_wait' then now() end,
         reminded_at = null, remind_count = 0, updated_at = now()
   where id = r.id;
  insert into sf_attendance_request_events(request_id, actor, action, via, note, data)
  values (r.id, p_actor, 'resubmitted', p_via, v_reason, jsonb_build_object('round', r.round + 1, 'old', v_old, 'before', v_before,
    'after', jsonb_build_object('clock_in', p_clock_in, 'clock_out', p_clock_out, 'break_start_1', p_break_start_1, 'break_end_1', p_break_end_1,
                                'break_start_2', p_break_start_2, 'break_end_2', p_break_end_2)));
  perform set_config('sf_att.op', '', true);
  select sf_attendance_request_state(x) into v_state from sf_attendance_requests x where x.id = r.id;
  return jsonb_build_object('ok', true, 'request_id', r.id, 'state', v_state, 'round', r.round + 1, 'actor_name', v_name);
end $$;
revoke all on function public.sf_attendance_request_resubmit(uuid, uuid, timestamptz, timestamptz, text, timestamptz, timestamptz, timestamptz, timestamptz, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_resubmit(uuid, uuid, timestamptz, timestamptz, text, timestamptz, timestamptz, timestamptz, timestamptz, text) to service_role;

-- ============ 10. 質問と回答（同じ申請の履歴に残す。承認にはならない） ============
--   一次承認者が書く＝質問（一次承認待ち → 本人確認中）／対象の本人・申請した人が書く＝回答（本人確認中 → 一次承認待ち）
create or replace function public.sf_attendance_request_message(p_request_id uuid, p_actor uuid, p_body text, p_via text default 'portal')
returns jsonb language plpgsql security definer set search_path = public as $$
declare r sf_attendance_requests%rowtype; v_name text; v_body text := trim(coalesce(p_body, '')); v_kind text; v_state text;
begin
  select name into v_name from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  if length(v_body) not between 1 and 500 then return jsonb_build_object('ok', false, 'code', 'invalid', 'message', '500 字以内で入れてください'); end if;
  select * into r from sf_attendance_requests where id = p_request_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この申請は見つかりません'); end if;
  if r.flow is distinct from 'two_stage' or r.status <> 'pending' or not coalesce(r.stage in ('first_wait', 'asking'), false) then
    return jsonb_build_object('ok', false, 'code', 'wrong_stage', 'message', '質問と回答は、一次承認の段階のあいだだけ書けます');
  end if;
  if r.first_approver_id is not distinct from p_actor then v_kind := 'question';
  elsif coalesce(p_actor = r.user_id, false) or coalesce(p_actor = r.requested_by, false) then v_kind := 'answer';
  else return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この申請に書けるのは、一次承認者・対象の本人・申請した人だけです');
  end if;
  perform set_config('sf_att.op', r.id::text, true);
  if v_kind = 'question' and r.stage = 'first_wait' then
    update sf_attendance_requests set stage = 'asking', updated_at = now() where id = r.id;
  elsif v_kind = 'answer' and r.stage = 'asking' then
    update sf_attendance_requests set stage = 'first_wait', updated_at = now() where id = r.id;
  end if;
  insert into sf_attendance_request_events(request_id, actor, action, via, note) values (r.id, p_actor, v_kind, p_via, v_body);
  perform set_config('sf_att.op', '', true);
  select sf_attendance_request_state(x) into v_state from sf_attendance_requests x where x.id = r.id;
  return jsonb_build_object('ok', true, 'request_id', r.id, 'kind', v_kind, 'state', v_state, 'actor_name', v_name);
end $$;
revoke all on function public.sf_attendance_request_message(uuid, uuid, text, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_message(uuid, uuid, text, text) to service_role;

-- ============ 11. スマレジへ送る前の札（同時に 2 回送らない）と、失敗のあとの再実行 ============
--   p_actor が null＝最終承認の直後の 1 回目／p_actor あり＝人が［もう一度スマレジへ送る］を押した（失敗のときだけ・その店舗を管理できる人）
create or replace function public.sf_attendance_request_sync_claim(p_request_id uuid, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r sf_attendance_requests%rowtype;
begin
  select * into r from sf_attendance_requests where id = p_request_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この申請は見つかりません'); end if;
  if r.status <> 'approved' then
    return jsonb_build_object('ok', false, 'code', 'not_approved', 'message', '最終承認が済んでいないため、スマレジへは送りません');
  end if;
  if coalesce(r.smaregi_sync_status, '') in ('synced', 'skipped') then
    return jsonb_build_object('ok', false, 'code', 'already_synced', 'message', 'すでにスマレジへ反映済みです');
  end if;
  if coalesce(r.smaregi_sync_status, '') = 'pending' and r.sync_claimed_at is not null and r.sync_claimed_at > now() - interval '3 minutes' then
    return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'いま、スマレジへ送っている最中です。少し待ってください');
  end if;
  if p_actor is not null then
    if coalesce(r.smaregi_sync_status, '') <> 'failed' then
      return jsonb_build_object('ok', false, 'code', 'not_failed', 'message', 'もう一度送れるのは、スマレジへの反映に失敗したときだけです');
    end if;
    if not coalesce(sf_can_manage_as(p_actor, r.store_id), false) then
      return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この店舗の勤怠をスマレジへ送り直す権限がありません');
    end if;
    insert into sf_attendance_request_events(request_id, actor, action, via, note) values (r.id, p_actor, 'sync_retry', null, left(coalesce(r.smaregi_error, ''), 300));
  end if;
  update sf_attendance_requests set smaregi_sync_status = 'pending', sync_claimed_at = now(), updated_at = now() where id = r.id;
  return jsonb_build_object('ok', true, 'request_id', r.id);
end $$;
revoke all on function public.sf_attendance_request_sync_claim(uuid, uuid) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_sync_claim(uuid, uuid) to service_role;

-- ============ 12. 一次承認者の設定（社長だけ）。設定したら、その店舗の「確認待ち」の申請が動き出す ============
--   p_user=null で未設定に戻す。service_role から呼ぶときは p_actor に操作した人を渡す。ログインした人が直接呼ぶときは、その人（p_actor は使わない）
create or replace function public.sf_attendance_first_approver_set(p_store uuid, p_user uuid, p_actor uuid default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; v_role text; v_old uuid; v_linked boolean; v_route jsonb; q record; v_moved uuid[] := '{}';
begin
  if onboarding_is_service() then v_actor := p_actor; else v_actor := auth.uid(); end if;
  select role into v_role from users where id = v_actor and is_active;
  if coalesce(v_role, '') <> 'CEO' then
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', '一次承認者を設定できるのは社長だけです');
  end if;
  if not exists (select 1 from stores where id = p_store and is_active) then
    return jsonb_build_object('ok', false, 'code', 'invalid', 'message', '店舗が見つかりません');
  end if;
  if p_user is not null and not exists (select 1 from users where id = p_user and is_active and deactivated_at is null) then
    return jsonb_build_object('ok', false, 'code', 'invalid', 'message', '在職の従業員を選んでください');
  end if;
  select approver_user_id into v_old from sf_attendance_first_approvers where store_id = p_store;
  if p_user is null then
    delete from sf_attendance_first_approvers where store_id = p_store;
  else
    insert into sf_attendance_first_approvers(store_id, approver_user_id, note, updated_at, updated_by)
    values (p_store, p_user, nullif(trim(coalesce(p_note, '')), ''), now(), v_actor)
    on conflict (store_id) do update set approver_user_id = excluded.approver_user_id, note = excluded.note, updated_at = excluded.updated_at, updated_by = excluded.updated_by;
  end if;
  insert into sf_attendance_first_approver_changes(store_id, old_user_id, new_user_id, changed_by, note)
  values (p_store, v_old, p_user, v_actor, nullif(trim(coalesce(p_note, '')), ''));
  if p_user is not null then
    for q in select id, store_id, requested_by, user_id from sf_attendance_requests
              where store_id = p_store and status = 'pending' and flow = 'two_stage' and stage = 'hold' order by requested_at for update loop
      v_route := sf_attendance_request_route(q.store_id, q.requested_by, q.user_id);
      perform set_config('sf_att.op', q.id::text, true);
      update sf_attendance_requests
         set stage = v_route ->> 'stage', first_approver_id = nullif(v_route ->> 'first_approver_id', '')::uuid,
             first_skipped = coalesce((v_route ->> 'first_skipped')::boolean, false),
             final_requested_at = case when v_route ->> 'stage' = 'final_wait' then now() end, updated_at = now()
       where id = q.id;
      insert into sf_attendance_request_events(request_id, actor, action, via, data)
      values (q.id, v_actor, 'routed', 'system', v_route || jsonb_build_object('from_stage', 'hold'));
      v_moved := v_moved || q.id;
    end loop;
    perform set_config('sf_att.op', '', true);
  end if;
  select exists (select 1 from user_slack k where k.user_id = p_user) into v_linked;
  return jsonb_build_object('ok', true, 'store_id', p_store, 'old_user_id', v_old, 'new_user_id', p_user, 'slack_linked', v_linked, 'moved_request_ids', to_jsonb(v_moved));
end $$;
revoke all on function public.sf_attendance_first_approver_set(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.sf_attendance_first_approver_set(uuid, uuid, uuid, text) to authenticated, service_role;

-- ============ 13. 承認画面用の読み取り（中身・履歴・「あなたが今できる操作」）。Slack の ID は返さない ============
create or replace function public.sf_attendance_request_detail(p_request_id uuid, p_viewer uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  r sf_attendance_requests%rowtype; v jsonb; v_role text; v_master boolean; v_manage boolean; v_related boolean;
  v_first boolean; v_final boolean; v_pending2 boolean; v_events jsonb;
begin
  select * into r from sf_attendance_requests where id = p_request_id;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この申請は見つかりません'); end if;
  select role, coalesce(is_master, false) into v_role, v_master from users where id = p_viewer and is_active;
  if v_role is null then return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この申請を見る権限がありません'); end if;
  v_manage := coalesce(sf_can_manage_as(p_viewer, r.store_id), false);
  v_related := coalesce(p_viewer = r.user_id, false) or coalesce(p_viewer = r.requested_by, false) or coalesce(p_viewer = r.first_approver_id, false);
  if not (v_manage or v_related) then
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この申請を見る権限がありません');
  end if;
  v := sf_attendance_request_view(r.id);
  v_pending2 := r.status = 'pending' and coalesce(r.flow = 'two_stage', false);
  v_first := v_pending2 and coalesce(r.stage in ('first_wait', 'asking'), false) and coalesce(p_viewer = r.first_approver_id, false);
  v_final := v_pending2 and coalesce(r.stage = 'final_wait', false) and v_role = 'CEO';
  select coalesce(jsonb_agg(jsonb_build_object('at', e.at, 'actor', e.actor, 'actor_name', u.name, 'action', e.action, 'via', e.via, 'note', e.note) order by e.at), '[]'::jsonb)
    into v_events
    from sf_attendance_request_events e left join users u on u.id = e.actor where e.request_id = r.id;
  return jsonb_build_object('ok', true,
    'request', v -> 'request', 'store_name', v -> 'store_name', 'names', v -> 'names', 'source', v -> 'source',
    'state', sf_attendance_request_state(r), 'events', v_events,
    'can', jsonb_build_object(
      'first_approve', v_first and not (coalesce(p_viewer = r.requested_by, false) or coalesce(p_viewer = r.user_id, false)),
      'ask', v_first and coalesce(r.stage = 'first_wait', false),
      'return', v_first or v_final,
      'reject', v_first or v_final,
      'final_approve', v_final and not coalesce(p_viewer = r.user_id, false)
                       and not (coalesce(p_viewer = r.requested_by, false) and (r.first_decided_by is null or r.first_decided_by = p_viewer)),
      'resubmit', v_pending2 and coalesce(r.stage = 'returned', false) and (v_manage or coalesce(p_viewer = r.user_id, false) or coalesce(p_viewer = r.requested_by, false)),
      'message', v_pending2 and coalesce(r.stage in ('first_wait', 'asking'), false) and v_related,
      'retry_sync', r.status = 'approved' and coalesce(r.smaregi_sync_status = 'failed', false) and coalesce(r.flow = 'two_stage', false) and v_manage,
      'cancel', v_pending2 and (coalesce(p_viewer = r.requested_by, false) or (v_role = 'CEO' and coalesce(r.stage in ('hold', 'returned'), false))),
      'legacy_decide', r.status = 'pending' and r.flow is null and v_master));
end $$;
revoke all on function public.sf_attendance_request_detail(uuid, uuid) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_detail(uuid, uuid) to service_role;

-- トリガー用の関数は、画面から直接は呼べないようにしておく（念のため）
revoke all on function public.sf_attendance_requests_flow_init() from public, anon, authenticated;
revoke all on function public.sf_attendance_requests_flow_routed() from public, anon, authenticated;
revoke all on function public.sf_attendance_requests_flow_guard() from public, anon, authenticated;
