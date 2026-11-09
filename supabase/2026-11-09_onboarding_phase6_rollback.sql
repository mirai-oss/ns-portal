-- 切り戻し: 2026-11-09_onboarding_phase6.sql（v2・データ保全版）
--   消すもの: Phase 6 の RPC・ビュー・トリガー・cron 関数・設定の追記キー・kind の 3 種（該当ジョブは cancelled にして残す）・ui_job_enqueue は Phase 2/3 版に戻す
--   残すもの: 表 employee_year_end / employee_year_end_snapshot / employee_dependents / employee_post_join_status / post_join_rules / post_join_overrides / post_join_policy_history（行ごと残す）・employee_tax_settings の 2 列・onboarding_events の記録
--   onboarding_workflow_v は Phase 5 時点の形（year_end / dependents 列なし）に作り直す
drop trigger if exists trg_post_join_class_change on public.users;
drop trigger if exists trg_post_join_rules_history on public.post_join_rules;
drop trigger if exists trg_post_join_overrides_history on public.post_join_overrides;
drop function if exists public.post_join_history_class_change();
drop function if exists public.post_join_history_rules();
drop function if exists public.post_join_history_overrides();
drop view if exists public.post_join_required_pending_v;
drop view if exists public.onboarding_post_join_v;
drop view if exists public.onboarding_workflow_v;
drop function if exists public.onboarding_save_year_end(uuid, jsonb, text, uuid, integer);
drop function if exists public.onboarding_save_dependents(uuid, jsonb, text, uuid);
drop function if exists public.onboarding_skip_post_join(uuid, text, uuid, integer, text);
drop function if exists public.onboarding_set_tax_setting(uuid, text, text, integer, integer, uuid);
drop function if exists public.onboarding_enqueue_year_end(uuid, uuid, integer);
drop function if exists public.onboarding_enqueue_dependents(uuid, uuid);
drop function if exists public.onboarding_post_join_targets(timestamptz, integer);
drop function if exists public.onboarding_post_join_reminded(uuid, text, integer);
drop function if exists public.onboarding_post_join_approve(uuid, text, integer, uuid, text);
drop function if exists public.onboarding_post_join_reject(uuid, text, integer, uuid, text);
drop function if exists public.onboarding_post_join_choice(uuid, text, text, uuid);
drop function if exists public.onboarding_post_join_overview(uuid, integer);
drop function if exists public.post_join_import_snapshot(uuid, jsonb, jsonb, uuid, integer);
drop function if exists public.post_join_set_override(uuid, text, integer, jsonb, text, uuid);
drop function if exists public.post_join_clear_override(uuid, text, integer, text, uuid);
drop function if exists public.post_join_set_rule(text, text, jsonb, text, uuid);
drop function if exists public.post_join_set_status_i(uuid, text, integer, text, uuid, text, text, text);
drop function if exists public.post_join_effective(uuid, text, integer);
drop function if exists public.post_join_effective_i(uuid, text, integer);
drop function if exists public.post_join_class(text);
-- employee_year_end.target_year の既定値が関数に依存するので、先に式の既定値へ差し替えてから関数を消す
alter table if exists public.employee_year_end alter column target_year set default extract(year from (now() at time zone 'Asia/Tokyo'))::int;
drop function if exists public.post_join_year_default();
drop function if exists public.smaregi_store_create_request(uuid, text, uuid);
drop function if exists public.smaregi_store_mapping_upsert(uuid, text, text, text);
drop function if exists public.onboarding_self_or_hq(uuid, uuid);
drop function if exists public.onboarding_post_join_remind_trigger();
update app_settings set value = value - 'post_join_remind_enabled' - 'post_join_remind_days' - 'post_join_repeat_days' where key = 'onboarding_alerts';
update public.ui_automation_jobs set status = 'cancelled', updated_at = now() where kind in ('smaregi_year_end','smaregi_dependents','smaregi_store') and status in ('pending','claimed','running');
update public.ui_automation_jobs set kind = 'smaregi_read', payload = payload || jsonb_build_object('_rolled_back_kind', kind) where kind in ('smaregi_year_end','smaregi_dependents','smaregi_store');
alter table public.ui_automation_jobs drop constraint if exists ui_automation_jobs_kind_check;
alter table public.ui_automation_jobs add constraint ui_automation_jobs_kind_check check (kind in ('smaregi_commute','smaregi_tax','smaregi_payslip','smaregi_email','smaregi_read'));
-- ui_job_enqueue を Phase 2/3 版に（内容は supabase/2026-11-10_onboarding_phase2_3.sql と同じ）
create or replace function public.ui_job_enqueue(p_workflow uuid, p_kind text, p_payload jsonb, p_actor uuid default null, p_dry_run boolean default false)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; wf onboarding_workflows%rowtype; v_item text; v_job uuid; v_staff text; v_contract text;
begin
  if auth.uid() is not null then v_actor := public.onboarding_resolve_actor(null);
  elsif public.onboarding_is_service() then v_actor := p_actor;
  else raise exception '認証が必要です'; end if;
  if p_kind not in ('smaregi_commute','smaregi_tax','smaregi_payslip','smaregi_email','smaregi_read') then raise exception '不正なジョブ種類です'; end if;
  if not coalesce(p_dry_run, false) and p_kind <> 'smaregi_read'
     and coalesce((select value ->> 'smaregi_write_enabled' from app_settings where key = 'commute_rules'), 'false') <> 'true' then
    return jsonb_build_object('ok', false, 'disabled', true, 'error', 'スマレジへの自動書き込みはまだ有効化されていません（実機検証後に app_settings.commute_rules.smaregi_write_enabled を true に）');
  end if;
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
  select l.contract_id, l.smaregi_staff_id into v_contract, v_staff from employee_smaregi_links l
   where l.user_id = wf.user_id and l.effective_to is null order by l.is_primary desc, l.effective_from desc limit 1;
  if v_staff is null then raise exception 'スマレジに登録されていないためジョブを作れません'; end if;
  v_item := case p_kind when 'smaregi_commute' then 'commute_set' when 'smaregi_tax' then 'withholding_tax' when 'smaregi_payslip' then 'web_payslip' when 'smaregi_email' then 'email' else null end;
  begin
    insert into ui_automation_jobs(kind, workflow_id, item_key, user_id, contract_id, smaregi_staff_id, payload, dry_run, requested_by)
    values (p_kind, p_workflow, v_item, wf.user_id, v_contract, v_staff, coalesce(p_payload, '{}'::jsonb), coalesce(p_dry_run, false), v_actor)
    returning id into v_job;
  exception when unique_violation then
    select id into v_job from ui_automation_jobs where smaregi_staff_id = v_staff and contract_id = v_contract and kind = p_kind and status in ('pending','claimed','running') limit 1;
    return jsonb_build_object('ok', true, 'job_id', v_job, 'duplicate', true);
  end;
  insert into ui_automation_job_log(job_id, message) values (v_job, '作成: ' || p_kind || case when coalesce(p_dry_run, false) then '（読むだけ）' else '' end);
  if v_item is not null and not coalesce(p_dry_run, false) then
    perform onboarding_set_item(p_workflow, v_item, 'retry_wait', jsonb_build_object('ui_job_id', v_job, 'queued_at', now()), v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, null);
  end if;
  insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, payload) values (p_workflow, v_item, 'ui_job.enqueued', v_actor, 'auto', jsonb_build_object('job_id', v_job, 'kind', p_kind, 'dry_run', p_dry_run));
  return jsonb_build_object('ok', true, 'job_id', v_job, 'duplicate', false);
end $$;
grant execute on function public.ui_job_enqueue(uuid, text, jsonb, uuid, boolean) to authenticated, service_role;
-- onboarding_workflow_v を Phase 5 時点の形に
create view public.onboarding_workflow_v as
select w.*, u.name as user_name, u.email as user_email, u.is_active as user_active,
       (select string_agg(s.name, '・' order by s.sort_order) from stores s where s.id = any(w.store_ids)) as store_names,
       (select jsonb_object_agg(i.item_key, jsonb_build_object('state', i.state, 'attempts', i.attempts, 'last_error', i.last_error, 'payload', i.payload, 'completed_at', i.completed_at, 'completion_source', i.completion_source))
          from onboarding_items i where i.workflow_id = w.id) as items,
       (select c.label from smaregi_contracts c where c.contract_id = w.contract_id limit 1) as contract_label
  from onboarding_workflows w left join users u on u.id = w.user_id;
alter view public.onboarding_workflow_v set (security_invoker = true);
grant select on public.onboarding_workflow_v to authenticated, service_role;

drop function if exists public.post_join_request_snapshot(uuid, integer, uuid);

drop function if exists public.post_join_payroll_deadline(date, integer, integer);
