-- 2026-11-19 担当B（社長の承認）— 勤怠の申請に「出勤取消」（その日の勤務の記録を丸ごと削除する申請）を足す
--  ・申請の種類 kind に 'delete' を足す（制約の作り直し）。出せる人・承認の流れは「勤怠修正」と同じ（本人／各店舗の管理者。一次承認 → 社長の最終承認）。理由は必須（1〜300 字）。
--  ・新しい関数 sf_attendance_request_submit_delete（申請を作る）。既存の申請の関数 sf_attendance_request_submit には触れない。
--  ・既存の関数 2 つの「1 か所だけ」を、中身が想定どおりのときだけ置き換える（想定と違えば、何も変えずに止まる）:
--      sf_attendance_request_summary … 種類の名前に「出勤取消」を足す
--      sf_attendance_request_decide   … 承認のとき、kind='delete' なら、勤怠実績（labor_cost_daily）と出勤記録（attendance_records）を削除（今の「打刻を消す」の承認と同じ処理）
--  ・スマレジの勤務実績の削除は、Edge Function smaregi-attendance-fix が、申請の控え（before_meta）の smaregi_shift_result_id で行う。
-- 【戻し方】kind の制約を 'add','fix' に戻す／drop function public.sf_attendance_request_submit_delete(...)／summary・decide は 2026-11-07・2026-11-14 の定義を再実行（delete の申請が無いことを確かめてから）
do $do$
declare v_name text; n int; v_def text; v_new text; v_oid oid;
  c_a constant text := 'case r.kind when ''add'' then ''勤怠追加'' else ''勤怠修正'' end';
  c_b constant text := '  if p_approve then';
begin
  -- 1) kind の制約に 'delete' を足す
  select count(*) into n from pg_constraint where conrelid = 'public.sf_attendance_requests'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%' and pg_get_constraintdef(oid) like '%add%' and pg_get_constraintdef(oid) like '%fix%';
  if n = 1 then
    select conname into v_name from pg_constraint where conrelid = 'public.sf_attendance_requests'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind%' and pg_get_constraintdef(oid) like '%add%' and pg_get_constraintdef(oid) like '%fix%';
    if (select pg_get_constraintdef(oid) from pg_constraint where conname = v_name and conrelid = 'public.sf_attendance_requests'::regclass) not like '%delete%' then
      execute format('alter table public.sf_attendance_requests drop constraint %I', v_name);
      alter table public.sf_attendance_requests add constraint sf_attendance_requests_kind_check check (kind in ('add', 'fix', 'delete'));
      raise notice 'kind の制約に delete を足しました';
    else raise notice 'kind の制約は、すでに delete を含みます（何もしません）'; end if;
  elsif exists (select 1 from pg_constraint where conrelid = 'public.sf_attendance_requests'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%delete%' and pg_get_constraintdef(oid) like '%kind%') then
    raise notice 'kind の制約は、すでに delete を含みます（何もしません）';
  else raise exception '停止: kind の制約が想定と違います（%件）', n; end if;

  -- 2) summary: 種類の名前
  select p.oid into v_oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'sf_attendance_request_summary';
  if v_oid is null then raise exception '停止: sf_attendance_request_summary がありません'; end if;
  v_def := pg_get_functiondef(v_oid);
  if position('出勤取消' in v_def) = 0 then
    if (length(v_def) - length(replace(v_def, c_a, ''))) / length(c_a) <> 1 then raise exception '停止: sf_attendance_request_summary の中身が想定と違います'; end if;
    execute replace(v_def, c_a, 'case r.kind when ''add'' then ''勤怠追加'' when ''delete'' then ''出勤取消'' else ''勤怠修正'' end');
    raise notice 'sf_attendance_request_summary を直しました';
  end if;

  -- 3) decide: 承認のとき kind='delete' の分岐
  select p.oid into v_oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'sf_attendance_request_decide';
  if v_oid is null then raise exception '停止: sf_attendance_request_decide がありません'; end if;
  v_def := pg_get_functiondef(v_oid);
  if position('r.kind = ''delete''' in v_def) = 0 then
    if (length(v_def) - length(replace(v_def, c_b, ''))) / length(c_b) <> 1 then raise exception '停止: sf_attendance_request_decide の中身が想定と違います'; end if;
    v_new := replace(v_def, c_b, E'  if p_approve and r.kind = ''delete'' then
    -- 出勤取消（2026-11-19）: 勤怠実績と出勤記録を消す（スマレジ側は EF が、申請の控えの smaregi_shift_result_id で DELETE）
    select * into l from labor_cost_daily where id = r.labor_cost_daily_id for update;
    if not found then return jsonb_build_object(''ok'', false, ''code'', ''no_record'', ''message'', ''元の勤怠実績が見つかりません（同期で消えた可能性）''); end if;
    delete from attendance_records where user_id = r.user_id and work_date = r.work_date;
    delete from labor_cost_daily where id = l.id;
    update sf_attendance_requests set status = ''approved'', decided_by = p_actor, decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '''')), ''''), applied_at = now(), updated_at = now() where id = r.id;
  elsif p_approve then');
    execute v_new;
    raise notice 'sf_attendance_request_decide を直しました';
  end if;
end $do$;

-- 4) 申請を作る（出勤取消）。EF attendance-request が service_role で呼ぶ
create or replace function public.sf_attendance_request_submit_delete(
  p_actor uuid, p_store_id uuid, p_user_id uuid, p_work_date date, p_reason text, p_via text default 'form')
returns jsonb language plpgsql security definer set search_path = public as $$
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
end $$;
revoke all on function public.sf_attendance_request_submit_delete(uuid, uuid, uuid, date, text, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_submit_delete(uuid, uuid, uuid, date, text, text) to service_role;
