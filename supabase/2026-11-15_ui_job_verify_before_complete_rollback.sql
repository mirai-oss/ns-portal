-- 2026-11-15_ui_job_verify_before_complete.sql の戻し（ui_job_finish を 2026-11-11 時点の本番の定義に戻す。足した関数と定期実行を外す。足した列は残す＝害が無いため）
do $$ begin
  if exists (select 1 from cron.job where jobname = 'ui-job-verify-sweep') then perform cron.unschedule('ui-job-verify-sweep'); end if;
end $$;
drop function if exists public.ui_job_verify_sweep();
drop function if exists public.ui_job_unverified();
drop function if exists public.ui_job_verify_record(uuid, boolean, text);
CREATE OR REPLACE FUNCTION public.ui_job_finish(p_job uuid, p_ok boolean, p_result jsonb DEFAULT NULL::jsonb, p_error text DEFAULT NULL::text, p_error_kind text DEFAULT NULL::text, p_screenshot text DEFAULT NULL::text, p_verified boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare j ui_automation_jobs%rowtype; v_final boolean; v_state text;
begin
  if not public.onboarding_is_service() then raise exception 'service_role のみ'; end if;
  select * into j from ui_automation_jobs where id = p_job for update;
  if j.id is null then return jsonb_build_object('ok', false, 'error', 'ジョブが見つかりません'); end if;
  if p_ok then
    update ui_automation_jobs set status = 'success', finished_at = now(), result = p_result, error = null, error_kind = null, screenshot_path = coalesce(p_screenshot, screenshot_path), updated_at = now() where id = j.id;
    insert into ui_automation_job_log(job_id, message) values (j.id, '成功' || case when p_verified then '（GET 照合一致）' when p_verified = false then '（GET 照合で不一致）' else '（照合なし）' end);
    if j.dry_run then return jsonb_build_object('ok', true, 'status', 'success', 'dry_run', true); end if;
    -- 反映先の表
    if j.kind = 'smaregi_commute' then
      update employee_commute_settings set sync_status = case when p_verified = false then 'error' else 'synced' end, sync_error = case when p_verified = false then '保存後の照合で不一致' else null end,
             verified_at = case when p_verified then now() else null end, verified_value = p_result, updated_at = now() where ui_job_id = j.id;
    elsif j.kind = 'smaregi_tax' then
      update employee_tax_settings set sync_status = case when p_verified = false then 'error' else 'synced' end, sync_error = case when p_verified = false then '保存後の照合で不一致' else null end,
             verified_at = case when p_verified then now() else null end, verified_value = p_result, updated_at = now() where ui_job_id = j.id;
    end if;
    if j.item_key is not null and j.workflow_id is not null then
      v_state := case when p_verified = false then 'failed' else 'completed' end;
      perform onboarding_set_item(j.workflow_id, j.item_key, v_state, jsonb_build_object('ui_job_id', j.id, 'verified', p_verified, 'result', p_result), null, 'auto',
                                  case when p_verified = false then '保存後の照合で不一致（スマレジの値が指示と違う）' else null end);
    end if;
    return jsonb_build_object('ok', true, 'status', 'success', 'item_state', v_state);
  end if;
  -- 失敗
  v_final := j.attempts >= j.max_attempts or p_error_kind in ('auth_expired','screen_changed');   -- 認証切れ・画面変更は再試行しても同じ→すぐ人へ
  update ui_automation_jobs set
    status = case when v_final then 'failed' else 'pending' end,
    next_retry_at = case when v_final then null else now() + (interval '10 minutes' * j.attempts) end,
    finished_at = case when v_final then now() else null end,
    error = left(p_error, 800), error_kind = p_error_kind, screenshot_path = coalesce(p_screenshot, screenshot_path), result = coalesce(p_result, result), updated_at = now()
  where id = j.id;
  insert into ui_automation_job_log(job_id, level, message) values (j.id, 'error', (case when v_final then '失敗（打ち切り）: ' else '失敗（再試行待ち）: ' end) || coalesce(p_error_kind, 'other') || ' ' || left(coalesce(p_error, ''), 300));
  if j.item_key is not null and j.workflow_id is not null and not j.dry_run then
    perform onboarding_set_item(j.workflow_id, j.item_key, case when v_final then 'manual_required' else 'retry_wait' end,
                                jsonb_build_object('ui_job_id', j.id, 'attempt', j.attempts, 'error_kind', p_error_kind), null, 'auto', left(p_error, 300));
  end if;
  if v_final and j.kind = 'smaregi_commute' then update employee_commute_settings set sync_status = 'error', sync_error = left(p_error, 300), updated_at = now() where ui_job_id = j.id; end if;
  if v_final and j.kind = 'smaregi_tax' then update employee_tax_settings set sync_status = 'error', sync_error = left(p_error, 300), updated_at = now() where ui_job_id = j.id; end if;
  return jsonb_build_object('ok', true, 'status', case when v_final then 'failed' else 'pending' end, 'final', v_final, 'attempts', j.attempts);
end $function$;
