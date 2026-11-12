-- 2026-11-19_onboarding_commute_one_step.sql の戻し（見回りと交通費の設定を元の定義に戻し、足した関数 3 つを外す）
create or replace function public.onboarding_auto_sweep()
returns jsonb language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/onboarding-notify';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  w record; r jsonb; v_secret text; n int := 0; n_changed int := 0; v_ch boolean;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  for w in select id from onboarding_workflows where status = 'registering' order by created_at limit 50 loop
    n := n + 1; v_ch := false;
    begin
      if onboarding_slack_link_refresh(w.id) then v_ch := true; end if;
      r := onboarding_auto_enqueue(w.id);
      if coalesce((r ->> 'changed')::boolean, false) then v_ch := true; end if;
    exception when others then
      raise warning 'onboarding_auto_sweep（%）: %', w.id, sqlerrm;
    end;
    if v_ch then
      n_changed := n_changed + 1;
      if v_secret is not null and length(trim(v_secret)) > 0 then
        perform net.http_post(url := c_fn,
          headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
          body := jsonb_build_object('op', 'refresh', 'workflow_id', w.id), timeout_milliseconds := 60000);
      end if;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'checked', n, 'changed', n_changed);
end $$;

CREATE OR REPLACE FUNCTION public.onboarding_set_commute_setting(p_workflow uuid, p_contract text, p_pay_type text, p_effective_date date, p_scope text, p_amount integer, p_store_amounts jsonb, p_cap_amount integer, p_cap_unit text, p_note text, p_actor uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_actor uuid; wf onboarding_workflows%rowtype; v_id uuid; v_job jsonb; v_payload jsonb;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
  if p_pay_type not in ('per_shift','per_day','monthly') then raise exception '支給形態が不正です'; end if;
  if p_scope not in ('all','per_store') then raise exception '適用事業所の区分が不正です'; end if;
  if p_scope = 'all' and (p_amount is null or p_amount < 0) then raise exception '金額を指定してください'; end if;
  if p_scope = 'per_store' and (p_store_amounts is null or p_store_amounts = '{}'::jsonb) then raise exception '事業所ごとの金額を指定してください'; end if;
  if p_effective_date is null then raise exception '適用開始日を指定してください'; end if;
  update employee_commute_settings set sync_status = case when sync_status in ('pending','queued') then 'manual' else sync_status end, updated_at = now()
   where user_id = wf.user_id and contract_id = p_contract and sync_status in ('pending','queued');   -- 未反映の古い指示は取り下げ
  insert into employee_commute_settings(user_id, workflow_id, contract_id, pay_type, effective_date, scope, amount, store_amounts, cap_amount, cap_unit, note, sync_status, created_by)
  values (wf.user_id, p_workflow, p_contract, p_pay_type, p_effective_date, p_scope, p_amount, p_store_amounts, p_cap_amount, coalesce(p_cap_unit, 'unknown'), p_note, 'pending', v_actor)
  returning id into v_id;
  v_payload := jsonb_build_object('setting_id', v_id, 'pay_type', p_pay_type, 'effective_date', p_effective_date, 'scope', p_scope, 'amount', p_amount, 'store_amounts', p_store_amounts, 'cap_amount', p_cap_amount, 'cap_unit', coalesce(p_cap_unit, 'unknown'));
  v_job := ui_job_enqueue(p_workflow, 'smaregi_commute', v_payload, v_actor, false);
  if coalesce(v_job ->> 'ok', 'false') = 'true' then
    update employee_commute_settings set ui_job_id = (v_job ->> 'job_id')::uuid, sync_status = 'queued', updated_at = now() where id = v_id;
  else
    -- 自動書き込みが未有効化（または作れない）: 確定値は残し、手動で管理画面に入れる（項目は manual_required）
    update employee_commute_settings set sync_status = 'manual', sync_error = v_job ->> 'error', updated_at = now() where id = v_id;
    perform onboarding_set_item(p_workflow, 'commute_set', 'manual_required', v_payload || jsonb_build_object('manual', true), v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, coalesce(v_job ->> 'error', '自動反映なし'));
  end if;
  insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, after) values (p_workflow, 'commute_set', 'commute.setting_saved', v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, v_payload);
  return jsonb_build_object('ok', true, 'setting_id', v_id, 'job', v_job);
end $function$
;

drop function if exists public.onboarding_commute_auto_search(uuid);
drop function if exists public.onboarding_commute_one_step(uuid, uuid);
drop function if exists public.onboarding_commute_defaults(uuid);
