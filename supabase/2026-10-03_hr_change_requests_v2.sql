-- ============================================================
-- 2026-10-03 担当B（nippo）— 退職申請 v2（ユーザー要望: 過去日の申請・取り消しの履歴と操作）
-- 【状態】事前報告（ユーザー確認待ち・未適用）。前提: 2026-10-03_hr_change_requests.sql 適用済み
--
-- 【理由】①実際に過去に退職した人の退職を後から申請できるようにする（30日前まで。承認すると即停止）
--   ②退職の取り消し（復職）をしても申請一覧に「承認済み」のまま残り、取り消した履歴が無かったため、
--     「取り消し済み」の状態と取り消しの操作（申請一覧から）を追加する
-- 【現構造】hr_change_requests.status は pending/approved/rejected のみ。取り消しは set_employee_termination(null)
--   （従業員編集の「退職を取り消す」）だけで、申請の履歴には反映されない。申請の退職日は「本日以降」のみ許可
-- 【影響】テーブルに列2つ（cancelled_by/cancelled_at）追加・statusに'cancelled'を許可（既存データは変わらない）。
--   既存RPC2つの変更（hr_request_retirement=退職日を30日前まで許可／set_employee_termination=復職時に
--   承認済み申請を取り消し済みにする）。新規RPC1つ（hr_cancel_retirement）。既存の行・既存の挙動は上記以外変えない
-- 【migration】本ファイル（冪等）。
-- 【rollback】hr_request_retirement／set_employee_termination を直前の定義へ戻す（元の定義は下のコメント）、
--   drop function hr_cancel_retirement(uuid); 列とcheckは残しても無害（statusに'cancelled'の行が無ければ）
-- 【元の定義】hr_request_retirement: 「if p_date is null or p_date < v_today then raise exception '退職日は本日以降の日付を指定してください'」
--   （他は同じ）／set_employee_termination: 2026-10-03_hr_change_requests.sql の §9 の定義
-- ============================================================

alter table hr_change_requests add column if not exists cancelled_by uuid references users(id);
alter table hr_change_requests add column if not exists cancelled_at timestamptz;
do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.hr_change_requests'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%pending%approved%rejected%' loop
    execute format('alter table hr_change_requests drop constraint %I', c);
  end loop;
  alter table hr_change_requests add constraint hr_change_requests_status_check
    check (status in ('pending','approved','rejected','cancelled'));
end $$;

-- ① 申請: 退職日は「30日前〜」を許可（過去日は承認時に即停止される）
create or replace function public.hr_request_retirement(p_store uuid, p_user uuid, p_date date)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date; v_id uuid; v_tdate date;
begin
  if not hr_can_act_store(p_store) then raise exception '権限がありません（この店舗の退職申請はできません）'; end if;
  if p_date is null or p_date < v_today - 30 then raise exception '退職日は30日前から先の日付を指定してください'; end if;
  if not exists(select 1 from user_stores where user_id = p_user and store_id = p_store) then
    raise exception 'この店舗に所属していない従業員です';
  end if;
  if not exists(select 1 from users where id = p_user and is_active) then raise exception '既に退職済み（無効）の従業員です'; end if;
  select termination_date into v_tdate from employee_profiles where user_id = p_user;
  if v_tdate is not null then raise exception '既に退職日が登録されている従業員です（%）', v_tdate; end if;
  begin
    insert into hr_change_requests(kind, store_id, user_id, effective_date, requested_by)
    values ('retirement', p_store, p_user, p_date, auth.uid()) returning id into v_id;
  exception when unique_violation then
    raise exception 'この従業員には承認待ちの退職申請が既にあります';
  end;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$function$;

-- ② 取り消し（復職）: 承認済みの退職申請を取り消し、退職日を消してログインを元に戻す。本部・社長・マスターのみ
--   （内部で set_employee_termination(user,null) を呼ぶ＝応募者の「退職」も「採用」へ戻る。申請は取り消し済みになる）
create or replace function public.hr_cancel_retirement(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r hr_change_requests%rowtype; v_tdate date;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  select * into r from hr_change_requests where id = p_request for update;
  if r.id is null then raise exception '申請が見つかりません'; end if;
  if r.status <> 'approved' then raise exception '承認済みの申請だけ取り消せます（現在: %）', r.status; end if;
  select termination_date into v_tdate from employee_profiles where user_id = r.user_id;
  if v_tdate is distinct from r.effective_date then
    raise exception '退職日が申請と異なります（現在の退職日: %）。従業員編集の退職日カードで確認してください', coalesce(v_tdate::text, '未登録');
  end if;
  perform set_employee_termination(r.user_id, null); -- 復職（この中で該当申請が取り消し済みになる）
  return jsonb_build_object('ok', true, 'request_id', r.id, 'user_id', r.user_id);
end;
$function$;
revoke all on function public.hr_cancel_retirement(uuid) from public, anon;
grant execute on function public.hr_cancel_retirement(uuid) to authenticated;

-- ③ 復職時に承認済み申請を取り消し済みにする（従業員編集の「退職を取り消す」経由でも履歴が残る）
create or replace function public.set_employee_termination(p_user uuid, p_date date)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_staff text; v_apps int := 0; v_name text; v_deact boolean := false;
        v_today date := (now() at time zone 'Asia/Tokyo')::date;
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
    -- 復職＝退職の取り消し: 承認済みの退職申請は「取り消し済み」にして履歴に残す（申請一覧で確認できる）
    update hr_change_requests set status = 'cancelled', cancelled_by = auth.uid(), cancelled_at = now(), updated_at = now()
     where user_id = p_user and kind = 'retirement' and status = 'approved';
    update applicants set status = 'hired', status_changed_at = now(), updated_at = now()
     where user_id = p_user and status = 'retired';
    get diagnostics v_apps = row_count;
  else
    if p_date < v_today then
      -- 退職日が昨日以前: その場で停止（退職日の翌日を既に過ぎているため）
      update users set is_active = false, deactivated_at = (p_date::timestamp at time zone 'Asia/Tokyo'), updated_at = now() where id = p_user;
      v_deact := true;
    end if;
    -- 退職日が今日以降: is_activeは触らない（退職日の翌日に hr_apply_due_terminations が停止）
    update applicants set status = 'retired', status_changed_at = now(), updated_at = now()
     where user_id = p_user and status <> 'retired';
    get diagnostics v_apps = row_count;
  end if;
  select smaregi_staff_id into v_staff from employee_profiles where user_id = p_user;
  return jsonb_build_object('ok', true, 'name', v_name, 'applicants', v_apps, 'smaregi_staff_id', v_staff, 'deactivated_now', v_deact);
end $function$;
