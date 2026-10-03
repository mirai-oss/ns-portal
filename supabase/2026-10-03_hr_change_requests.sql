-- ============================================================
-- 2026-10-03 担当B（nippo）— 退職申請・承認（Sync7）のDB側
-- 実装指示書_担当B_退職申請承認_2026-10-03.md §1・§8（Q1=a: 退職日の翌日に自動停止）
-- 【状態】⚠️下書き（未適用）。§6の set_employee_termination 改修だけは、既存関数の定義
--   （DB上にのみ存在・リポジトリに無い）を pg_get_functiondef で確認してから確定する。
--   §1〜§5（テーブル・申請/承認/却下RPC・自動停止RPC）は既存関数に依存しないが、承認RPCは
--   §6で改修した set_employee_termination を呼ぶため、§6が確定するまで一括適用はしない。
--
-- 【理由】店舗（店長・チーム長・本部）からの退職申請→本部の承認→退職日の登録、を画面から行うため。
-- 【現構造】退職処理は従業員編集の「退職日」カード→RPC set_employee_termination→smaregi-sync terminate
--   として既に存在（v2.6.8）。申請の仕組み（テーブル・RPC）は無い。
-- 【影響】新規テーブル1・新規RPC6・部分ユニーク索引1を追加。§6で既存RPC set_employee_termination の
--   挙動を「退職日を入れた瞬間に停止」から「退職日の翌日に停止（過去日なら即停止）」へ変更する
--   （＝既存の従業員編集の退職日カードも同じ規則に揃う。ユーザー確認済みのQ1=a）。
-- 【migration】本ファイル。【rollback】各関数・テーブルのdrop＋set_employee_termination を元の定義へ戻す
--   （元の定義は§6適用前に pg_get_functiondef の結果をWORKLOGへ保存しておく）
-- ============================================================

-- ① テーブル（kind列を持つが今回は'retirement'のみ。汎用エンジンは作らない＝要望19章）
create table if not exists hr_change_requests (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'retirement' check (kind in ('retirement')),
  store_id uuid not null references stores(id),
  user_id uuid not null references users(id),
  effective_date date not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_by uuid references users(id),
  requested_at timestamptz not null default now(),
  approved_by uuid references users(id),
  approved_at timestamptz,
  rejected_by uuid references users(id),
  rejected_at timestamptz,
  reject_reason text,
  sync_status text not null default 'none' check (sync_status in ('none','synced','unsynced','error')),
  sync_result jsonb,
  synced_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table hr_change_requests is '人事の変更申請（今回は退職申請のみ）。申請→本部承認。書き込みはRPC経由のみ（担当B・nippo所有・2026-10-03新設）';
-- 同一従業員の承認待ちの重複をDBで防止（要望11章）
create unique index if not exists hr_change_requests_one_pending
  on hr_change_requests(user_id) where status = 'pending' and kind = 'retirement';

-- ② 「この店舗を扱ってよい人か」（申請の作成・閲覧範囲。RLS述語でも使うため、権限が無ければ例外でなくfalse）
--   本部・社長・マスター=全店舗／チーム長=担当チームの店舗＋自分の所属店舗／店長=自分の所属店舗
create or replace function public.hr_can_act_store(p_store uuid)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_caller users%rowtype;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null then return false; end if;
  if v_caller.is_master or v_caller.role in ('CEO','HQ') then return true; end if;
  if v_caller.role = 'TEAM' then
    return p_store = any(team_store_ids(v_caller.team_id) || user_store_ids(v_caller.id));
  end if;
  if v_caller.role = 'TENCHO' then
    return p_store = any(user_store_ids(v_caller.id));
  end if;
  return false;
end;
$function$;
grant execute on function public.hr_can_act_store(uuid) to authenticated;

alter table hr_change_requests enable row level security;
drop policy if exists hr_change_requests_read on hr_change_requests;
create policy hr_change_requests_read on hr_change_requests for select using (hr_can_act_store(store_id));
-- insert/update/deleteポリシーは作らない＝直接の書き込みは全面拒否（下のRPCのみ）

-- ③ 申請（店長・チーム長・本部・社長・マスター）
create or replace function public.hr_request_retirement(p_store uuid, p_user uuid, p_date date)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date; v_id uuid; v_tdate date;
begin
  if not hr_can_act_store(p_store) then raise exception '権限がありません（この店舗の退職申請はできません）'; end if;
  if p_date is null or p_date < v_today then raise exception '退職日は本日以降の日付を指定してください'; end if;
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
grant execute on function public.hr_request_retirement(uuid, uuid, date) to authenticated;

-- ④ 承認（本部・社長・マスター）。1トランザクション。行ロック→最新状態を再検証→退職日を登録（既存RPCを呼ぶ）
create or replace function public.hr_approve_retirement(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r hr_change_requests%rowtype; v_tdate date; v_active boolean;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  select * into r from hr_change_requests where id = p_request for update; -- 承認の連打・二重承認防止
  if r.id is null then raise exception '申請が見つかりません'; end if;
  if r.status <> 'pending' then raise exception 'この申請は既に処理済みです（%）', r.status; end if;
  -- 承認時点の最新状態を再取得して検証（異動・退職済み・別経路での退職日登録）
  select is_active into v_active from users where id = r.user_id;
  if v_active is distinct from true then raise exception '対象の従業員は既に退職済み（無効）です'; end if;
  if not exists(select 1 from user_stores where user_id = r.user_id and store_id = r.store_id) then
    raise exception '申請後に所属店舗が変わっています。内容を確認して、必要なら申請をやり直してください';
  end if;
  select termination_date into v_tdate from employee_profiles where user_id = r.user_id;
  if v_tdate is not null then raise exception '既に退職日が登録されています（%）', v_tdate; end if;
  -- 既存RPC（§6で「退職日の翌日に停止／過去日なら即停止」へ改修）。退職日は申請の値をそのまま渡す＝一致を保証（要望7章）
  perform set_employee_termination(r.user_id, r.effective_date);
  update hr_change_requests set status = 'approved', approved_by = auth.uid(), approved_at = now(), updated_at = now() where id = r.id;
  select is_active into v_active from users where id = r.user_id;
  return jsonb_build_object('ok', true, 'request_id', r.id, 'user_id', r.user_id,
    'effective_date', r.effective_date, 'deactivated_now', not coalesce(v_active, true));
end;
$function$;
grant execute on function public.hr_approve_retirement(uuid) to authenticated;

-- ⑤ 却下
create or replace function public.hr_reject_retirement(p_request uuid, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r hr_change_requests%rowtype;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  select * into r from hr_change_requests where id = p_request for update;
  if r.id is null then raise exception '申請が見つかりません'; end if;
  if r.status <> 'pending' then raise exception 'この申請は既に処理済みです（%）', r.status; end if;
  update hr_change_requests set status = 'rejected', rejected_by = auth.uid(), rejected_at = now(),
    reject_reason = nullif(trim(coalesce(p_reason,'')), ''), updated_at = now() where id = r.id;
  return jsonb_build_object('ok', true);
end;
$function$;
grant execute on function public.hr_reject_retirement(uuid, text) to authenticated;

-- ⑥ スマレジ同期結果の記録（画面から。承認とは別トランザクション＝外部APIとDBを分離・要望16章）
create or replace function public.hr_record_retirement_sync(p_request uuid, p_status text, p_result jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  if p_status not in ('synced','unsynced','error') then raise exception '不正な同期状態です'; end if;
  update hr_change_requests set sync_status = p_status, sync_result = p_result, synced_at = now(), updated_at = now()
   where id = p_request and status = 'approved';
  if not found then raise exception '承認済みの申請が見つかりません'; end if;
  return jsonb_build_object('ok', true);
end;
$function$;
grant execute on function public.hr_record_retirement_sync(uuid, text, jsonb) to authenticated;

-- ⑦ 毎日の自動処理用（GitHub Actions・service_role専用）: 退職日の翌日以降でまだ在籍の人を停止し、対象user_idを返す
create or replace function public.hr_apply_due_terminations()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date; v_ids uuid[];
begin
  with due as (
    update users u set is_active = false,
           deactivated_at = ((ep.termination_date + 1)::timestamp at time zone 'Asia/Tokyo')
      from employee_profiles ep
     where ep.user_id = u.id and u.is_active and ep.termination_date is not null and ep.termination_date < v_today
    returning u.id
  )
  select coalesce(array_agg(id), array[]::uuid[]) into v_ids from due;
  return jsonb_build_object('ok', true, 'users', to_jsonb(v_ids));
end;
$function$;
revoke all on function public.hr_apply_due_terminations() from public, anon, authenticated;
grant execute on function public.hr_apply_due_terminations() to service_role;

-- ⑧ 自動停止後のスマレジ打刻OFFの結果を、その人の承認済み退職申請へ記録（GitHub Actions・service_role専用）
create or replace function public.hr_record_deactivation_result(p_user uuid, p_ok boolean, p_result jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_id uuid;
begin
  select id into v_id from hr_change_requests
   where user_id = p_user and kind = 'retirement' and status = 'approved' order by approved_at desc limit 1;
  if v_id is null then return jsonb_build_object('ok', true, 'recorded', false); end if; -- 申請を経ない退職（従来の退職日カード）は記録先なし
  update hr_change_requests
     set sync_result = coalesce(sync_result, '{}'::jsonb) || jsonb_build_object('deactivate', coalesce(p_result, '{}'::jsonb)),
         sync_status = case when not p_ok then 'error' when sync_status = 'none' then 'synced' else sync_status end,
         synced_at = now(), updated_at = now()
   where id = v_id;
  return jsonb_build_object('ok', true, 'recorded', true);
end;
$function$;
revoke all on function public.hr_record_deactivation_result(uuid, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.hr_record_deactivation_result(uuid, boolean, jsonb) to service_role;

-- ============================================================
-- §6 set_employee_termination の改修（★未確定。既存定義を確認してから書く）
--   目標の挙動（Q1=a）:
--     p_date が null      → 復職: employee_profiles.termination_date=null・users.is_active=true・deactivated_at=null（従来どおり即時）
--     p_date < 今日(JST)  → 退職日が過去: termination_date登録＋その場で is_active=false・deactivated_at=p_date+1
--     p_date >= 今日(JST) → 退職日のみ登録。is_active は触らない（退職日の翌日に hr_apply_due_terminations が停止）
--     いずれも従来の副作用（応募者管理の状況を「退職」へ更新し、件数を {applicants:n} で返す）は維持
--   → 既存の本文（応募者更新の条件等）が分からないと書き換えられないため、pg_get_functiondef の結果を見て確定する
-- ============================================================
