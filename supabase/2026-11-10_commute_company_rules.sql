-- =============================================================
-- 交通費の会社ルール（2026-11-10・中山さん回答）★ 未適用（承認後に適用）
--   1) app_settings.commute_rules に会社ルールを追記: IC 運賃・新幹線/特急なし・バスは原則不可・1 日上限 500 円（往復）・上限の単位＝月額（スマレジ画面で確認済み）
--   2) employee_commute に個別の支給方法（daily_cap＝1 日上限（基本）／teiki＝定期代支給／full＝全額支給）・バス例外 を追加。★ 決められるのは本部だけ（従業員は選べない。2026-11-10 運用方針）
--   2b) 出勤見込みは自己申告ではなくシフト（sf_shifts）と出勤実績（labor_cost_daily）から取る: 関数 commute_days_stats
--   3) RPC onboarding_set_commute_policy（本部のみ・理由必須・履歴 onboarding_events）
--   既存の行: employee_commute の既存行は pay_policy='daily_cap'（既定）になるだけで、金額・承認状態は変えない
--   切り戻し: 2026-11-10_commute_company_rules_rollback.sql（データ保全）
-- =============================================================
update app_settings
   set value = value || jsonb_build_object(
         'fare_type', coalesce(value ->> 'fare_type', 'ic'),
         'allow_bus', coalesce((value ->> 'allow_bus')::boolean, false),
         'allow_express', coalesce((value ->> 'allow_express')::boolean, false),
         'daily_cap_round_yen', coalesce((value ->> 'daily_cap_round_yen')::int, 500),
         'use_address_lookup', coalesce((value ->> 'use_address_lookup')::boolean, false),
         'cap_unit', 'month',
         'note', '交通費の会社ルール（2026-11-10 確定）: IC 運賃・新幹線/特急なし・バスは原則不可（本部が個別に例外承認）・基本は 1 日上限 500 円（往復）。月額上限＝アルバイトの基本 6,000 円（al_cap_yen）／社員の基本 なし／定期代支給・全額支給（本部の個別承認）は標準上限を適用しない（本部が個別に月額上限を設定可）。支給方法と金額は本部が決める。スマレジの「交通費の上限」は月額。※雇用契約・就業規則との整合は未確認'),
       updated_at = now()
 where key = 'commute_rules';

alter table public.employee_commute add column if not exists pay_policy text not null default 'daily_cap';
alter table public.employee_commute drop constraint if exists employee_commute_pay_policy_check;
alter table public.employee_commute add constraint employee_commute_pay_policy_check check (pay_policy in ('daily_cap','teiki','full'));
alter table public.employee_commute add column if not exists bus_exception boolean not null default false;
-- 月額上限の個別設定（null=標準: アルバイトの基本＝commute_rules.al_cap_yen（6,000）／社員の基本＝なし／定期代・全額支給＝なし）。スマレジの「交通費の上限（月額）」に入れる値の初期値に使う
alter table public.employee_commute add column if not exists monthly_cap_override integer check (monthly_cap_override is null or monthly_cap_override between 0 and 999999);
alter table public.employee_commute add column if not exists policy_reason text;
alter table public.employee_commute add column if not exists policy_by uuid;
alter table public.employee_commute add column if not exists policy_at timestamptz;

-- 個別の支給方法を決める（本部・社長・マスターだけ。従業員は不可）。基本（1 日上限）以外やバス例外は理由必須。変更は onboarding_events に履歴として残る
create or replace function public.onboarding_set_commute_policy(p_user uuid, p_policy text, p_bus_exception boolean, p_reason text, p_actor uuid default null, p_monthly_cap integer default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; c employee_commute%rowtype; v_before jsonb; v_wf uuid;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_policy not in ('daily_cap','teiki','full') then raise exception '支給方法が不正です'; end if;
  if p_monthly_cap is not null and (p_monthly_cap < 0 or p_monthly_cap > 999999) then raise exception '月額上限が不正です'; end if;
  -- 基本（1 日上限・標準の月額上限）と違う扱い＝定期代／全額／バス例外／月額上限の個別設定 は理由必須
  if (p_policy <> 'daily_cap' or coalesce(p_bus_exception, false) or p_monthly_cap is not null) and nullif(trim(coalesce(p_reason, '')), '') is null then raise exception '理由を入れてください（基本ルールと違う扱いにするため）'; end if;
  select id into v_wf from onboarding_workflows where user_id = p_user;
  select * into c from employee_commute where user_id = p_user for update;
  if c.user_id is null then
    insert into employee_commute(user_id, workflow_id, submitted_via) values (p_user, v_wf, 'hq_policy') returning * into c;
  end if;
  v_before := jsonb_build_object('pay_policy', c.pay_policy, 'bus_exception', c.bus_exception, 'monthly_cap_override', c.monthly_cap_override, 'reason', c.policy_reason);
  update employee_commute set pay_policy = p_policy, bus_exception = coalesce(p_bus_exception, false), monthly_cap_override = p_monthly_cap,
         policy_reason = nullif(trim(coalesce(p_reason, '')), ''), policy_by = v_actor, policy_at = now(), updated_at = now()
   where user_id = p_user;
  if coalesce(c.workflow_id, v_wf) is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (coalesce(c.workflow_id, v_wf), 'commute_check', 'commute.policy_set', v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, v_before,
            jsonb_build_object('pay_policy', p_policy, 'bus_exception', coalesce(p_bus_exception, false), 'monthly_cap_override', p_monthly_cap, 'reason', nullif(trim(coalesce(p_reason, '')), '')));
  end if;
  return jsonb_build_object('ok', true, 'pay_policy', p_policy, 'bus_exception', coalesce(p_bus_exception, false), 'monthly_cap_override', p_monthly_cap, 'workflow_id', coalesce(c.workflow_id, v_wf));
end $$;
revoke all on function public.onboarding_set_commute_policy(uuid, text, boolean, text, uuid, integer) from public, anon;
grant execute on function public.onboarding_set_commute_policy(uuid, text, boolean, text, uuid, integer) to authenticated, service_role;

-- 出勤日数（判断材料）: 自己申告は使わず、シフト（sf_shifts の休み以外の日）と出勤実績（labor_cost_daily）から数える。本部・service のみ
create or replace function public.commute_days_stats(p_user uuid)
returns jsonb
language plpgsql security definer stable set search_path to 'public'
as $$
declare d date := (now() at time zone 'Asia/Tokyo')::date; m0 date; r jsonb;
begin
  if not (public.onboarding_is_service() or public.hq_can_manage()) then raise exception '権限がありません'; end if;
  m0 := date_trunc('month', d)::date;
  select jsonb_build_object(
    'this_month', to_char(m0, 'YYYY-MM'), 'next_month', to_char(m0 + interval '1 month', 'YYYY-MM'), 'last_month', to_char(m0 - interval '1 month', 'YYYY-MM'),
    'shift_days_this_month', (select count(distinct s.work_date) from sf_shifts s where s.user_id = p_user and not coalesce(s.is_off, false) and s.work_date >= m0 and s.work_date < m0 + interval '1 month'),
    'shift_days_next_month', (select count(distinct s.work_date) from sf_shifts s where s.user_id = p_user and not coalesce(s.is_off, false) and s.work_date >= m0 + interval '1 month' and s.work_date < m0 + interval '2 month'),
    'actual_days_last_month', (select count(distinct l.work_date) from labor_cost_daily l where l.user_id = p_user and l.work_date >= m0 - interval '1 month' and l.work_date < m0),
    'actual_days_this_month_so_far', (select count(distinct l.work_date) from labor_cost_daily l where l.user_id = p_user and l.work_date >= m0 and l.work_date <= d),
    'actual_months_3m', (select count(distinct date_trunc('month', l.work_date)) from labor_cost_daily l where l.user_id = p_user and l.work_date >= m0 - interval '3 month' and l.work_date < m0),
    'actual_days_3m', (select count(distinct l.work_date) from labor_cost_daily l where l.user_id = p_user and l.work_date >= m0 - interval '3 month' and l.work_date < m0)
  ) into r;
  return r;
end $$;
revoke all on function public.commute_days_stats(uuid) from public, anon;
grant execute on function public.commute_days_stats(uuid) to authenticated, service_role;
