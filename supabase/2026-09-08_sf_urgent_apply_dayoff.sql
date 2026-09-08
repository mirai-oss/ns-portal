-- 2026-09-08 担当B（nippo）
-- ユーザー指示「①急募機能を完成させる（不足枠→急募作成→LINE通知→従業員応募→
-- 管理者採用→sf_shiftsへ反映→スマレジ同期→実勤務完了→急募対応回数・時間を
-- ダッシュボードへ反映）②人事シフトの休日必要数をハードコードしない」に対応。

-- ① 急募応募テーブル（誰が応募したか）
create table if not exists sf_urgent_shift_applications (
  id uuid primary key default gen_random_uuid(),
  urgent_shift_id uuid not null references sf_urgent_shifts(id) on delete cascade,
  user_id uuid not null references users(id),
  status text not null default 'applied' check (status in ('applied','hired','rejected','cancelled')),
  applied_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references users(id),
  unique(urgent_shift_id, user_id)
);
comment on table sf_urgent_shift_applications is '急募シフトへの応募（担当B・nippo所有・2026-09-08新設）';
alter table sf_urgent_shift_applications enable row level security;
drop policy if exists sf_urgent_apps_select on sf_urgent_shift_applications;
create policy sf_urgent_apps_select on sf_urgent_shift_applications for select using (
  user_id = auth.uid() or exists(
    select 1 from sf_urgent_shifts u join users mgr on mgr.id = auth.uid()
    where u.id = urgent_shift_id and mgr.is_active and (
      mgr.is_master or mgr.role in ('CEO','HQ') or
      ((mgr.role in ('TENCHO','TEAM')) and u.store_id = any(
        case when mgr.role = 'TEAM' then team_store_ids(mgr.team_id) else user_store_ids(mgr.id) end
      ))
    )
  )
);
-- 応募・採用・却下の書き込みは狭いRPC経由のみに限定する（下記）。直接insert/updateは許可しない

-- sf_urgent_shiftsに採用者・実勤務完了の追跡列を追加
alter table sf_urgent_shifts
  add column if not exists hired_user_id uuid references users(id),
  add column if not exists work_start_time text,
  add column if not exists work_end_time text;
comment on column sf_urgent_shifts.hired_user_id is '採用（確定）した応募者。急募対応回数の集計に使う';

-- ① 応募する（従業員本人）
create or replace function public.sf_urgent_shift_apply(p_urgent_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_u sf_urgent_shifts%rowtype;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select * into v_u from sf_urgent_shifts where id = p_urgent_id;
  if v_u.id is null then raise exception '対象の急募が見つかりません'; end if;
  if v_u.status <> 'open' then raise exception 'この急募は既に締め切られています'; end if;
  insert into sf_urgent_shift_applications(urgent_shift_id, user_id) values (p_urgent_id, auth.uid())
    on conflict (urgent_shift_id, user_id) do update set status = 'applied', applied_at = now();
  return jsonb_build_object('ok', true);
end;
$function$;
grant execute on function public.sf_urgent_shift_apply(uuid) to authenticated;

-- ① 採用する（店長以上）。sf_shiftsへ反映まで一括で行う
create or replace function public.sf_urgent_shift_hire(p_urgent_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_u sf_urgent_shifts%rowtype;
  v_caller users%rowtype;
  v_period_key text;
begin
  select * into v_caller from users c0 where c0.id = auth.uid() and c0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ','TENCHO','TEAM')) then
    raise exception '権限がありません';
  end if;
  select * into v_u from sf_urgent_shifts where id = p_urgent_id;
  if v_u.id is null then raise exception '対象の急募が見つかりません'; end if;
  if v_u.status <> 'open' then raise exception 'この急募は既に処理済みです'; end if;
  if not exists(select 1 from sf_urgent_shift_applications where urgent_shift_id = p_urgent_id and user_id = p_user_id) then
    raise exception 'この人はこの急募に応募していません';
  end if;

  -- sf_shiftsへ反映（period_keyは既存の半月キー規則 "YYYY-M-A/B" に合わせる）
  v_period_key := to_char(v_u.work_date, 'YYYY') || '-' || extract(month from v_u.work_date)::text || '-' ||
    (case when extract(day from v_u.work_date) <= 15 then 'A' else 'B' end);
  insert into sf_shifts(user_id, store_id, work_date, period_key, start_time, end_time, break_minutes, is_off, status, created_by, updated_at)
  values (p_user_id, v_u.store_id, v_u.work_date, v_period_key, v_u.start_time, v_u.end_time, 0, false, 'draft', auth.uid(), now())
  on conflict (user_id, work_date) do update set
    store_id = excluded.store_id, start_time = excluded.start_time, end_time = excluded.end_time,
    is_off = false, updated_at = now();

  update sf_urgent_shifts set status = 'filled', hired_user_id = p_user_id, filled_by = auth.uid(), filled_at = now()
    where id = p_urgent_id;
  update sf_urgent_shift_applications set status = 'hired', decided_at = now(), decided_by = auth.uid()
    where urgent_shift_id = p_urgent_id and user_id = p_user_id;
  update sf_urgent_shift_applications set status = 'rejected', decided_at = now(), decided_by = auth.uid()
    where urgent_shift_id = p_urgent_id and user_id <> p_user_id and status = 'applied';

  return jsonb_build_object('ok', true);
end;
$function$;
grant execute on function public.sf_urgent_shift_hire(uuid, uuid) to authenticated;

-- ② 休日必要数の設定テーブル（社員マスタ相当。店舗・雇用形態・個人ごとに設定可）
create table if not exists sf_dayoff_requirements (
  id uuid primary key default gen_random_uuid(),
  store_id uuid references stores(id), -- nullは全店舗共通
  role text, -- nullは全役職共通。'SHAIN'/'TENCHO'/'TEAM'/'AL'等
  user_id uuid references users(id), -- 指定時は個人設定として最優先
  required_days_half_month integer not null default 4,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(store_id, role, user_id)
);
comment on table sf_dayoff_requirements is '半月あたりの休日必要数の設定（担当B・nippo所有・2026-09-08新設）。人事シフト（全店舗横断）の休日基準判定に使用。個人指定＞店舗+役職＞店舗のみ＞役職のみ＞全社共通(4行すべてnull)の優先順で適用し、該当設定が1件も無ければ半月4日を初期値とする';
alter table sf_dayoff_requirements enable row level security;
drop policy if exists sf_dayoff_requirements_select on sf_dayoff_requirements;
create policy sf_dayoff_requirements_select on sf_dayoff_requirements for select using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active)
);
drop policy if exists sf_dayoff_requirements_write on sf_dayoff_requirements;
create policy sf_dayoff_requirements_write on sf_dayoff_requirements for all using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
) with check (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
);
