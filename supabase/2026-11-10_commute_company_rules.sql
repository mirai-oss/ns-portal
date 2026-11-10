-- =============================================================
-- 交通費の会社ルール（2026-11-10・中山さん回答）★ 未適用（承認後に適用）
--   1) app_settings.commute_rules に会社ルールを追記: IC 運賃・新幹線/特急なし・バスは原則不可・1 日上限 500 円（往復）・上限の単位＝月額（スマレジ画面で確認済み）
--   2) employee_commute に個別の支給方法（daily_cap＝1 日上限（基本）／teiki＝定期代支給／full＝全額支給）・月の出勤日数の見込み・バス例外 を追加
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
         'note', '交通費の会社ルール（2026-11-10 確定）: IC 運賃・新幹線/特急なし・バスは原則不可（個別に例外）・1 日上限 500 円（往復）が基本。超える人は個別に定期代支給か全額支給。定期と実費は安い方。スマレジの「交通費の上限」は月額'),
       updated_at = now()
 where key = 'commute_rules';

alter table public.employee_commute add column if not exists pay_policy text not null default 'daily_cap';
alter table public.employee_commute drop constraint if exists employee_commute_pay_policy_check;
alter table public.employee_commute add constraint employee_commute_pay_policy_check check (pay_policy in ('daily_cap','teiki','full'));
alter table public.employee_commute add column if not exists expected_days_per_month integer check (expected_days_per_month is null or expected_days_per_month between 1 and 31);
alter table public.employee_commute add column if not exists bus_exception boolean not null default false;
alter table public.employee_commute add column if not exists policy_reason text;
alter table public.employee_commute add column if not exists policy_by uuid;
alter table public.employee_commute add column if not exists policy_at timestamptz;

-- 個別の支給方法を決める（本部・社長・マスター。Slack の「⚙️ 支給方法」/ nippo から）。理由必須（基本の 1 日上限に戻すときは不要）
create or replace function public.onboarding_set_commute_policy(p_user uuid, p_policy text, p_days integer, p_bus_exception boolean, p_reason text, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; c employee_commute%rowtype; v_before jsonb; v_wf uuid;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_policy not in ('daily_cap','teiki','full') then raise exception '支給方法が不正です'; end if;
  if p_days is not null and (p_days < 1 or p_days > 31) then raise exception '出勤日数の見込みは 1〜31 で入れてください'; end if;
  if (p_policy <> 'daily_cap' or coalesce(p_bus_exception, false)) and nullif(trim(coalesce(p_reason, '')), '') is null then raise exception '理由を入れてください（基本ルールと違う扱いにするため）'; end if;
  select id into v_wf from onboarding_workflows where user_id = p_user;
  select * into c from employee_commute where user_id = p_user for update;
  if c.user_id is null then
    insert into employee_commute(user_id, workflow_id, submitted_via) values (p_user, v_wf, 'hq_policy') returning * into c;
  end if;
  v_before := jsonb_build_object('pay_policy', c.pay_policy, 'expected_days_per_month', c.expected_days_per_month, 'bus_exception', c.bus_exception);
  update employee_commute set pay_policy = p_policy, expected_days_per_month = p_days, bus_exception = coalesce(p_bus_exception, false),
         policy_reason = nullif(trim(coalesce(p_reason, '')), ''), policy_by = v_actor, policy_at = now(), updated_at = now()
   where user_id = p_user;
  if coalesce(c.workflow_id, v_wf) is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (coalesce(c.workflow_id, v_wf), 'commute_check', 'commute.policy_set', v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, v_before,
            jsonb_build_object('pay_policy', p_policy, 'expected_days_per_month', p_days, 'bus_exception', coalesce(p_bus_exception, false), 'reason', nullif(trim(coalesce(p_reason, '')), '')));
  end if;
  return jsonb_build_object('ok', true, 'pay_policy', p_policy, 'expected_days_per_month', p_days, 'bus_exception', coalesce(p_bus_exception, false), 'workflow_id', coalesce(c.workflow_id, v_wf));
end $$;
revoke all on function public.onboarding_set_commute_policy(uuid, text, integer, boolean, text, uuid) from public, anon;
grant execute on function public.onboarding_set_commute_policy(uuid, text, integer, boolean, text, uuid) to authenticated, service_role;
