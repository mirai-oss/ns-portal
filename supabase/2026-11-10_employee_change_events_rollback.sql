-- 戻し: 従業員情報の変更イベント（2026-11-10_employee_change_events.sql）を取り消す。記録した履歴も消えるので、残したい場合は先に退避すること
drop trigger if exists employee_change_users on users;
drop trigger if exists employee_change_profiles on employee_profiles;
drop trigger if exists employee_change_user_stores_ins on user_stores;
drop trigger if exists employee_change_user_stores_del on user_stores;
drop trigger if exists employee_change_user_stores_upd on user_stores;
drop trigger if exists employee_change_bank on payroll_bank_accounts;
drop trigger if exists employee_change_wage on employee_wage_settings;
drop trigger if exists employee_change_profile_request on profile_change_requests;
drop trigger if exists employee_change_commute on employee_commute;
-- onboarding_save_commute を変更前の定義に戻す
CREATE OR REPLACE FUNCTION public.onboarding_save_commute(p_user uuid, p_method text, p_route_text text, p_claimed_fare integer, p_uses_bus boolean, p_note text, p_via text DEFAULT 'nippo_join'::text, p_actor uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_actor uuid; v_wf uuid; v_station text; v_before jsonb;
begin
  if auth.uid() is not null then
    if auth.uid() <> p_user and not exists (select 1 from users x where x.id = auth.uid() and x.is_active and (x.is_master or x.role in ('CEO','HQ'))) then
      raise exception '権限がありません';
    end if;
    v_actor := auth.uid();
  elsif public.onboarding_is_service() then
    v_actor := p_actor;
  else
    raise exception '認証が必要です';
  end if;
  if p_method is not null and p_method not in ('train','bus','train_bus','bike','walk','car','other') then raise exception '通勤手段が不正です'; end if;
  if p_claimed_fare is not null and (p_claimed_fare < 0 or p_claimed_fare > 100000) then raise exception '片道交通費が不正です'; end if;
  select id into v_wf from onboarding_workflows where user_id = p_user;
  select extra ->> '最寄り駅' into v_station from employee_profiles where user_id = p_user;
  select to_jsonb(c) - 'search_result' into v_before from employee_commute c where c.user_id = p_user;
  insert into employee_commute(user_id, workflow_id, method, home_station, route_text, claimed_oneway_fare, uses_bus, special_note, submitted_at, submitted_via)
  values (p_user, v_wf, p_method, v_station, nullif(trim(coalesce(p_route_text, '')), ''), p_claimed_fare, p_uses_bus, nullif(trim(coalesce(p_note, '')), ''), now(), coalesce(p_via, 'nippo_join'))
  on conflict (user_id) do update set
    workflow_id = coalesce(employee_commute.workflow_id, excluded.workflow_id), method = excluded.method, home_station = coalesce(excluded.home_station, employee_commute.home_station),
    route_text = excluded.route_text, claimed_oneway_fare = excluded.claimed_oneway_fare, uses_bus = excluded.uses_bus, special_note = excluded.special_note,
    submitted_at = now(), submitted_via = excluded.submitted_via,
    -- 申請内容が変わったら判定をやり直す（承認済みは残す）
    judgement = case when employee_commute.judgement = 'approved' then 'approved' else null end, judgement_reasons = '{}'::text[], judged_at = null,
    updated_at = now();
  if v_wf is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (v_wf, 'commute_check', 'commute.submitted', v_actor, case when p_via like 'slack%' then 'slack' when auth.uid() is null then 'system' else 'nippo' end, v_before,
            jsonb_build_object('method', p_method, 'claimed_oneway_fare', p_claimed_fare, 'uses_bus', p_uses_bus, 'has_route', p_route_text is not null));
    -- 項目: 申請が来たら commute_check を pending に戻す（検索は EF commute-route が行う）
    update onboarding_items set state = 'pending', completion_source = null, completed_at = null, updated_at = now()
     where workflow_id = v_wf and item_key = 'commute_check' and state in ('pending','failed','manual_required','retry_wait');
  end if;
  return jsonb_build_object('ok', true, 'workflow_id', v_wf, 'home_station', v_station);
end $function$;
drop function if exists employee_change_my_recheck();
drop function if exists employee_change_list(uuid, integer);
drop function if exists employee_change_effect_resolve(uuid, text, text, uuid);
drop function if exists employee_change_set_dates(uuid, date, date, uuid);
drop function if exists employee_change_trg_commute();
drop function if exists employee_change_trg_profile_request();
drop function if exists employee_change_trg_wage();
drop function if exists employee_change_trg_bank();
drop function if exists employee_change_trg_user_stores();
drop function if exists employee_change_trg_profiles();
drop function if exists employee_change_trg_users();
drop function if exists employee_change_log_error(text, text, uuid, text);
drop function if exists employee_change_record(uuid, text, text, text, jsonb, jsonb, date);
drop function if exists employee_change_group_of_request(text);
drop function if exists employee_change_retract(uuid);
drop function if exists employee_change_notify(uuid);
drop function if exists employee_change_dispatch(uuid);
drop function if exists employee_change_work_store(jsonb);
drop function if exists employee_change_stores_state(uuid);
drop function if exists employee_change_effective_hint(date, date);
alter table employee_commute drop column if exists recheck_required_at, drop column if exists recheck_effect_id, drop column if exists recheck_reason;
drop table if exists employee_change_effect_events;
drop table if exists employee_change_effects;
drop table if exists employee_change_events;
drop table if exists employee_change_errors;
drop table if exists employee_change_rules;
delete from app_settings where key = 'employee_change';
