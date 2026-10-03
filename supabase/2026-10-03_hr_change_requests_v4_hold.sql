-- ============================================================
-- 2026-10-03 担当B（nippo）— 退職申請 v4: 源泉徴収票が済むまで「実際の停止」を待たせる
-- 【状態】事前報告（ユーザー確認待ち・未適用）。前提: v1〜v3 適用済み
--
-- 【理由】ユーザー要望: 退職処理（ログイン停止・スマレジの退職反映）が先に済むと、源泉徴収票が取れなくなる。
--   退職手続きの本部タスクの「源泉徴収票」の工程が終わる（または従業員編集から源泉徴収票を登録する）までは、
--   実際の停止を待たせる（選択肢A）。
-- 【現構造】set_employee_termination は退職日が昨日以前なら、その場でis_active=falseにする。
--   hr_apply_due_terminations（毎朝の自動停止）は退職日を過ぎた人を無条件で停止する
-- 【変更】
--   ① 新ヘルパー hr_slip_pending(p_user): その人の退職手続きタスクに「源泉徴収票の工程が未完了」で、かつ
--      その年の源泉徴収票がまだ登録されていない＝true（待つ）。タスクが無い人はfalse（待たない）
--   ② set_employee_termination: 退職日を入れても、その場では停止しない（is_activeを触らない）。復職(null)は従来どおり
--   ③ 新RPC hr_finalize_retirement(p_user): 「退職日を過ぎていて、源泉徴収票を待たなくてよい」なら停止する。
--      画面から、退職承認の直後・退職日カードの保存直後・源泉徴収票の登録直後に呼ぶ
--   ④ hr_apply_due_terminations（毎朝）: 同じ条件（待つ人は止めない）。戻り値に退職日つきの items を追加
-- 【影響】既存データは変えない。「過去日の承認で即停止」は「源泉徴収票が済んだ時点で停止」に変わる
--   （タスクが無い人は従来どおりすぐ停止）。これまでに退職日を入れて停止済みの人は何も変わらない
-- 【migration】本ファイル（冪等）。
-- 【rollback】set_employee_termination／hr_apply_due_terminations を直前の定義（v2のSQLファイル・
--   2026-10-03_hr_change_requests.sql）へ戻し、hr_finalize_retirement・hr_slip_pending を drop
-- ============================================================

create or replace function public.hr_slip_pending(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1
      from hq_task_steps st
      join hq_tasks t on t.id = st.task_id
     where t.related_user_id = p_user
       and t.task_category = 'offboarding'
       and t.deleted_at is null
       and st.action_kind = 'offboarding_tax_slip'
       and st.completed_at is null
       and not exists (select 1 from hr_documents d
                        where d.user_id = p_user and d.kind = 'withholding_slip'
                          and d.year is not distinct from nullif(st.action_payload->>'year', '')::int)
  );
$function$;
revoke all on function public.hr_slip_pending(uuid) from public, anon;
grant execute on function public.hr_slip_pending(uuid) to authenticated;

-- ② 退職日の登録（その場では停止しない）
create or replace function public.set_employee_termination(p_user uuid, p_date date)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_staff text; v_apps int := 0; v_name text;
begin
  if not exists (select 1 from users where id = auth.uid() and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（社長・本部・マスターのみ）';
  end if;
  if p_user = auth.uid() then raise exception '自分自身には設定できません'; end if;
  select name into v_name from users where id = p_user;
  if v_name is null then raise exception '対象の従業員が見つかりません'; end if;
  insert into employee_profiles (user_id) values (p_user) on conflict (user_id) do nothing;
  update employee_profiles set termination_date = p_date, updated_at = now() where user_id = p_user;
  if p_date is null then
    update users set is_active = true, deactivated_at = null, updated_at = now() where id = p_user;
    update hr_change_requests set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(), updated_at = now()
     where user_id = p_user and kind = 'retirement' and status = 'approved';
    update applicants set status = 'hired', status_changed_at = now(), updated_at = now()
     where user_id = p_user and status = 'retired';
    get diagnostics v_apps = row_count;
  else
    -- 停止（is_active=false）はここでは行わない。hr_finalize_retirement（画面から）と毎朝の自動停止が、
    -- 「退職日を過ぎた」かつ「源泉徴収票を待たなくてよい」ときに行う
    update applicants set status = 'retired', status_changed_at = now(), updated_at = now()
     where user_id = p_user and status <> 'retired';
    get diagnostics v_apps = row_count;
  end if;
  select smaregi_staff_id into v_staff from employee_profiles where user_id = p_user;
  return jsonb_build_object('ok', true, 'name', v_name, 'applicants', v_apps, 'smaregi_staff_id', v_staff, 'deactivated_now', false);
end $function$;

-- ③ 停止してよければ停止する（本部・社長・マスターが画面から呼ぶ）
create or replace function public.hr_finalize_retirement(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date; v_date date; v_active boolean; v_req uuid;
begin
  if not exists (select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  select ep.termination_date, u.is_active into v_date, v_active
    from users u left join employee_profiles ep on ep.user_id = u.id where u.id = p_user;
  if not found then raise exception '対象の従業員が見つかりません'; end if;
  select id into v_req from hr_change_requests
   where user_id = p_user and kind = 'retirement' and status = 'approved' order by approved_at desc limit 1;
  if v_date is null then return jsonb_build_object('ok', true, 'stopped', false, 'reason', 'no_date', 'request_id', v_req); end if;
  if not v_active then return jsonb_build_object('ok', true, 'stopped', false, 'reason', 'already', 'date', v_date, 'request_id', v_req); end if;
  if v_date >= v_today then return jsonb_build_object('ok', true, 'stopped', false, 'reason', 'not_due', 'date', v_date, 'request_id', v_req); end if;
  if hr_slip_pending(p_user) then return jsonb_build_object('ok', true, 'stopped', false, 'reason', 'slip_pending', 'date', v_date, 'request_id', v_req); end if;
  update users set is_active = false, deactivated_at = (v_date::timestamp at time zone 'Asia/Tokyo'), updated_at = now() where id = p_user;
  return jsonb_build_object('ok', true, 'stopped', true, 'date', v_date, 'request_id', v_req);
end;
$function$;
revoke all on function public.hr_finalize_retirement(uuid) from public, anon;
grant execute on function public.hr_finalize_retirement(uuid) to authenticated;

-- ④ 毎朝の自動停止（待つ人は止めない。退職日つきのitemsも返す）
create or replace function public.hr_apply_due_terminations()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date; v_ids uuid[]; v_items jsonb;
begin
  with due as (
    update users u set is_active = false,
           deactivated_at = (ep.termination_date::timestamp at time zone 'Asia/Tokyo')
      from employee_profiles ep
     where ep.user_id = u.id and u.is_active and ep.termination_date is not null and ep.termination_date < v_today
       and not hr_slip_pending(u.id)
    returning u.id as uid, ep.termination_date as d
  )
  select coalesce(array_agg(uid), array[]::uuid[]),
         coalesce(jsonb_agg(jsonb_build_object('user_id', uid, 'date', d)), '[]'::jsonb)
    into v_ids, v_items from due;
  return jsonb_build_object('ok', true, 'users', to_jsonb(v_ids), 'items', v_items);
end;
$function$;
