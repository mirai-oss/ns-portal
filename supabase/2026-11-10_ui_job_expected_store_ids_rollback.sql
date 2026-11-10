-- 戻し: ui_job_enqueue を 2026-11-10 変更前（expected_store_ids なし）の定義に戻す
CREATE OR REPLACE FUNCTION public.ui_job_enqueue(p_workflow uuid, p_kind text, p_payload jsonb, p_actor uuid DEFAULT NULL::uuid, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_actor uuid; wf onboarding_workflows%rowtype; v_item text; v_job uuid; v_staff text; v_contract text; v_payload jsonb;
begin
  if auth.uid() is not null then v_actor := public.onboarding_resolve_actor(null);
  elsif public.onboarding_is_service() then v_actor := p_actor;
  else raise exception '認証が必要です'; end if;
  if p_kind not in ('smaregi_commute','smaregi_tax','smaregi_payslip','smaregi_email','smaregi_read','smaregi_year_end','smaregi_dependents','smaregi_store') then raise exception '不正なジョブ種類です'; end if;
  -- ★ 安全スイッチ: app_settings.commute_rules.smaregi_write_enabled が true になるまで、書き込みジョブは作らない（読むだけ smaregi_read / dry_run は可）
  if not coalesce(p_dry_run, false) and p_kind <> 'smaregi_read'
     and coalesce((select value ->> 'smaregi_write_enabled' from app_settings where key = 'commute_rules'), 'false') <> 'true' then
    return jsonb_build_object('ok', false, 'disabled', true, 'error', 'スマレジへの自動書き込みはまだ有効化されていません（実機検証後に app_settings.commute_rules.smaregi_write_enabled を true に）');
  end if;
  if p_kind = 'smaregi_store' then
    if coalesce(p_payload ->> 'store_id', '') = '' or coalesce(p_payload ->> 'contract_id', '') = '' then raise exception '店舗ジョブには payload.store_id と contract_id が必要です'; end if;
    v_staff := 'store:' || (p_payload ->> 'store_id'); v_contract := p_payload ->> 'contract_id'; v_item := null;
  else
    select * into wf from onboarding_workflows where id = p_workflow;
    if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
    select l.contract_id, l.smaregi_staff_id into v_contract, v_staff from employee_smaregi_links l
     where l.user_id = wf.user_id and l.effective_to is null order by l.is_primary desc, l.effective_from desc limit 1;
    if v_staff is null then raise exception 'スマレジに登録されていないためジョブを作れません'; end if;
    v_item := case p_kind when 'smaregi_commute' then 'commute_set' when 'smaregi_tax' then 'withholding_tax' when 'smaregi_payslip' then 'web_payslip' when 'smaregi_email' then 'email' else null end;
    -- 書き込み前の 3 点確認（2026-11-09 ユーザー指示）: Mac 側が 契約ID・従業員ID・所属事業所 を画面で照合してから書く。期待値を payload に必ず入れる
    --   expected_stores = その人の user_stores の店舗を、その契約の store_external_mappings（smaregi_timecard・有効・期間内）の external_store_name に変換。対応が無い店舗は stores.name のまま
    v_payload := coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('expected_contract_id', v_contract, 'expected_staff_id', v_staff,
      'expected_stores', (select coalesce(jsonb_agg(coalesce(
            (select m.external_store_name from store_external_mappings m join smaregi_contracts c on c.corporation_hint = m.corporation_hint and c.contract_id = v_contract
              where m.store_id = s.id and m.source_system = 'smaregi_timecard' and m.is_active and (m.effective_from is null or m.effective_from <= current_date) and (m.effective_to is null or m.effective_to >= current_date)
              order by m.effective_from desc nulls last limit 1), s.name) order by s.sort_order), '[]'::jsonb)
         from user_stores us join stores s on s.id = us.store_id where us.user_id = wf.user_id));
  end if;
  begin
    insert into ui_automation_jobs(kind, workflow_id, item_key, user_id, contract_id, smaregi_staff_id, payload, dry_run, requested_by)
    values (p_kind, case when p_kind = 'smaregi_store' then null else p_workflow end, v_item, wf.user_id, v_contract, v_staff, coalesce(v_payload, p_payload, '{}'::jsonb), coalesce(p_dry_run, false), v_actor)
    returning id into v_job;
  exception when unique_violation then
    select id into v_job from ui_automation_jobs where smaregi_staff_id = v_staff and contract_id = v_contract and kind = p_kind and status in ('pending','claimed','running') limit 1;
    return jsonb_build_object('ok', true, 'job_id', v_job, 'duplicate', true);
  end;
  insert into ui_automation_job_log(job_id, message) values (v_job, '作成: ' || p_kind || case when coalesce(p_dry_run, false) then '（読むだけ）' else '' end);
  if v_item is not null and not coalesce(p_dry_run, false) then
    perform onboarding_set_item(p_workflow, v_item, 'retry_wait', jsonb_build_object('ui_job_id', v_job, 'queued_at', now()), v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, null);
  end if;
  if p_workflow is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, payload) values (p_workflow, v_item, 'ui_job.enqueued', v_actor, 'auto', jsonb_build_object('job_id', v_job, 'kind', p_kind, 'dry_run', p_dry_run));
  end if;
  return jsonb_build_object('ok', true, 'job_id', v_job, 'duplicate', false);
end $function$;
