-- =============================================================
-- 固定残業代の「設定・管理」だけ（最小版・2026-11-16 社長の方針変更。担当D）
--   やること: 月給の行（employee_wage_settings・division=2）に、固定残業代の「状態・金額・時間数（基本 45 時間）」を記録する。
--   やらないこと: 給与計算・割増賃金の計算・超過分の計算・深夜/休日の区分・スマレジへの送信（対応できる項目と方法を確かめてから別途）。
--   守ること: 基本給（wage）・適用開始日・同期の状態は一切変えない（既存の月給総額・給与データは自動で変わらない）／既存社員への一括反映なし／
--             monthly_wage_sync_hold は触らない（この更新は「中身が同じ」扱いなので、止めの見張りも通る）。
--   注意: 45 時間分の固定残業代で、法定の割増賃金が満たされるとは限らない。実際の給与計算と、法令上必要な差額の支払いは、今ある処理のまま。
--   実際の従業員データへの書き込みは、このファイルでは行わない（列と関数を足すだけ。値は、本部・社長が画面で入れる）。
-- ロールバック: 2026-12-13_fixed_ot_min_rollback.sql
-- =============================================================

alter table employee_wage_settings
  add column if not exists fixed_ot_state   text not null default 'unknown',   -- unknown=未設定／none=なし／applied=あり
  add column if not exists fixed_ot_amount  integer,                          -- 固定残業代（円）。applied のときだけ
  add column if not exists fixed_ot_minutes integer,                          -- 対象の時間数（分）。基本 2700（=45 時間）。applied のときだけ
  add column if not exists fixed_ot_set_by  uuid references users(id),
  add column if not exists fixed_ot_set_at  timestamptz;
alter table employee_wage_settings drop constraint if exists employee_wage_settings_fixed_ot_chk;
alter table employee_wage_settings add constraint employee_wage_settings_fixed_ot_chk check (
  fixed_ot_state in ('unknown', 'none', 'applied')
  and (fixed_ot_state = 'unknown' or division = 2)                                   -- 月給の行だけ
  and (fixed_ot_state = 'applied' or (fixed_ot_amount is null and fixed_ot_minutes is null))
  and (fixed_ot_state <> 'applied' or (fixed_ot_amount between 1 and 10000000 and fixed_ot_minutes between 60 and 12000))
);
comment on column employee_wage_settings.fixed_ot_state is '固定残業代の状態（unknown 未設定／none なし／applied あり）。管理システム内の記録だけ（スマレジへは送らない）';

-- 変更の記録（足すだけ。画面からは直接読めない）
create table if not exists fixed_ot_changes (
  id          uuid primary key default gen_random_uuid(),
  wage_id     uuid not null,
  user_id     uuid not null,
  before_value jsonb,
  after_value  jsonb,
  actor       uuid,
  changed_at  timestamptz not null default now()
);
alter table fixed_ot_changes enable row level security;
revoke all on fixed_ot_changes from anon, authenticated;

-- 設定の入口（本部・社長・マスターだけ。ログインした人の権限で動く。基本給・日付・同期の状態は触らない）
create or replace function public.hr_set_fixed_ot(p_id uuid, p_state text, p_amount integer default null, p_minutes integer default 2700)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; w employee_wage_settings%rowtype; v_cfg jsonb;
begin
  v_actor := public.onboarding_resolve_actor(null);   -- ログインした人（本部・社長・マスターだけ。なりすまし不可）
  if p_state not in ('none', 'applied', 'unknown') then raise exception '状態は none / applied / unknown のどれかです'; end if;
  select * into w from employee_wage_settings where id = p_id for update;
  if not found then raise exception '賃金の行が見つかりません'; end if;
  if w.division <> 2 then raise exception '固定残業代を設定できるのは月給の行だけです'; end if;
  -- 賃金変更の「申請 → 承認」の仕組みが ON のときは、ここから直接は変えない（承認を迂回しないため。承認の流れへの対応は別途）
  select value into v_cfg from app_settings where key = 'employee_change';
  if coalesce((v_cfg ->> 'wage_approval_required')::boolean, false) then
    raise exception '賃金の変更は申請・承認が必要な設定です。固定残業代の申請への対応は、まだできていません';
  end if;
  if p_state = 'applied' then
    if p_amount is null or p_amount < 1 or p_amount > 10000000 then raise exception '固定残業代の金額が不正です'; end if;
    if p_minutes is null or p_minutes < 60 or p_minutes > 12000 then raise exception '対象の時間数が不正です（1〜200 時間）'; end if;
  end if;
  update employee_wage_settings
     set fixed_ot_state = p_state,
         fixed_ot_amount = case when p_state = 'applied' then p_amount end,
         fixed_ot_minutes = case when p_state = 'applied' then p_minutes end,
         fixed_ot_set_by = v_actor, fixed_ot_set_at = now()
   where id = w.id;   -- 基本給・適用開始日・同期の状態は更新しない（updated_at も触らない＝同期の判定に影響しない）
  insert into fixed_ot_changes(wage_id, user_id, before_value, after_value, actor)
  values (w.id, w.user_id,
          jsonb_build_object('state', w.fixed_ot_state, 'amount', w.fixed_ot_amount, 'minutes', w.fixed_ot_minutes),
          jsonb_build_object('state', p_state, 'amount', case when p_state = 'applied' then p_amount end, 'minutes', case when p_state = 'applied' then p_minutes end),
          v_actor);
  return jsonb_build_object('ok', true, 'id', w.id, 'state', p_state);
end $$;
revoke all on function public.hr_set_fixed_ot(uuid, text, integer, integer) from public, anon;
grant execute on function public.hr_set_fixed_ot(uuid, text, integer, integer) to authenticated;
