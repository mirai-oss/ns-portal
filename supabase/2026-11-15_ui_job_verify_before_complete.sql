-- =============================================================
-- 入社登録の自動操作: 「照合してから完了」にする（2026-11-11 ユーザー指示・最優先の不具合修正）
--   今まで: 自動操作（Mac の Playwright）が終わった時点で項目を「完了」にし、そのあとの照合で不一致なら「失敗」に戻していた。
--           照合の呼び出しが失敗すると、照合していないのに「完了」のまま残った。
--   これから: ① 登録 → ② スマレジを読み直す → ③ 指示した値と照合 → ④ 一致したときだけ「完了」 → ⑤ 不一致は「失敗」、読み直せないときは「照合待ち」のまま。
--   変えるもの:
--     1. ui_job_finish … 照合の結果（p_verified）が無いあいだは、項目を「処理中（照合待ち）」にする。設定の表も「同期済み」にしない。
--     2. ui_automation_jobs に 照合の結果（verified・verified_at・verify_attempts）の列を足す。
--     3. ui_job_verify_record … 照合の結果を記録する入口（Edge Function onboarding-notify が呼ぶ）。5 回読み直せなければ、項目を「手動対応が必要」にして本部タスクに工程を足す。
--     4. ui_job_unverified / ui_job_verify_sweep … 成功で終わったのに照合の結果が無いジョブを拾い、照合をやり直す（10 分おき）。
--   二重登録の防止は今までどおり: 同じ従業員×同じ種類の未完了ジョブは作れない（ui_job_enqueue）／Mac 側は同じ設定が既にあれば保存しない。
--   Mac 側（ns-daily-import）の変更は不要（p_verified は今までどおり null で呼ぶ）。
--   戻し方: 2026-11-15_ui_job_verify_before_complete_rollback.sql
-- =============================================================
do $$ begin
  if (select md5(prosrc) from pg_proc where proname = 'ui_job_finish' and pronamespace = 'public'::regnamespace) not in ('13e57ba0777d3d78051a9854bf0517fd', 'acbcf595763221c91abb74620b3968a5') then
    raise exception 'ui_job_finish の本番の定義が、基準（2026-11-11 に確認したもの）と違います。適用を中止します';
  end if;
end $$;

alter table public.ui_automation_jobs add column if not exists verified boolean;
alter table public.ui_automation_jobs add column if not exists verified_at timestamptz;
alter table public.ui_automation_jobs add column if not exists verify_attempts integer not null default 0;
-- これまでの成功したジョブ（テスト従業員の 4 件。どれも照合済み）は、やり直しの対象にしない
update public.ui_automation_jobs set verified = true, verified_at = coalesce(finished_at, updated_at)
 where status = 'success' and not dry_run and verified is null and finished_at < now();

-- ui_job_finish（本番の定義に、照合待ちの扱いだけを差し込んだもの）
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
    update ui_automation_jobs set status = 'success', finished_at = now(), result = p_result, error = null, error_kind = null, screenshot_path = coalesce(p_screenshot, screenshot_path), updated_at = now(),
           verified = p_verified, verified_at = case when p_verified is not null then now() else null end where id = j.id;
    insert into ui_automation_job_log(job_id, message) values (j.id, '成功' || case when p_verified then '（GET 照合一致）' when p_verified = false then '（GET 照合で不一致）' else '（照合待ち）' end);
    if j.dry_run then return jsonb_build_object('ok', true, 'status', 'success', 'dry_run', true); end if;
    -- 反映先の表
    if j.kind = 'smaregi_commute' then
      update employee_commute_settings set sync_status = case when p_verified = false then 'error' when p_verified then 'synced' else sync_status end, sync_error = case when p_verified = false then '保存後の照合で不一致' else null end,
             verified_at = case when p_verified then now() else null end, verified_value = p_result, updated_at = now() where ui_job_id = j.id;
    elsif j.kind = 'smaregi_tax' then
      update employee_tax_settings set sync_status = case when p_verified = false then 'error' when p_verified then 'synced' else sync_status end, sync_error = case when p_verified = false then '保存後の照合で不一致' else null end,
             verified_at = case when p_verified then now() else null end, verified_value = p_result, updated_at = now() where ui_job_id = j.id;
    end if;
    if j.item_key is not null and j.workflow_id is not null then
      v_state := case when p_verified = false then 'failed' when p_verified then 'completed' else 'running' end;   -- 2026-11-15: 照合の前に完了にしない
      perform onboarding_set_item(j.workflow_id, j.item_key, v_state, jsonb_build_object('ui_job_id', j.id, 'verified', p_verified, 'verify', case when p_verified is null then 'pending' else 'done' end, 'result', p_result), null, 'auto',
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

-- 照合の結果を記録する（Edge Function onboarding-notify から。service_role だけ）
--   p_verified: true＝一致／false＝不一致／null＝読み直せなかった（通信エラーなど）
create or replace function public.ui_job_verify_record(p_job uuid, p_verified boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare j ui_automation_jobs%rowtype; v_max constant int := 5; v_escalated boolean := false;
begin
  if not public.onboarding_is_service() then raise exception 'service_role のみ'; end if;
  select * into j from ui_automation_jobs where id = p_job for update;
  if j.id is null then return jsonb_build_object('ok', false, 'error', 'ジョブが見つかりません'); end if;
  if j.status <> 'success' or j.dry_run then return jsonb_build_object('ok', true, 'skipped', true); end if;
  update ui_automation_jobs set verify_attempts = verify_attempts + 1,
         verified = coalesce(p_verified, verified), verified_at = case when p_verified is not null then now() else verified_at end, updated_at = now()
   where id = j.id returning * into j;
  insert into ui_automation_job_log(job_id, level, message)
  values (j.id, case when p_verified then 'info' else 'error' end,
          case when p_verified then '照合: 一致' when p_verified = false then '照合: 不一致' else '照合できず（' || j.verify_attempts || '/' || v_max || ' 回）' || coalesce(' ' || left(p_note, 200), '') end);
  -- 読み直せないまま上限に達した: 完了にはせず、人の確認へ（本部タスクに工程を足す）
  if p_verified is null and j.verified is null and j.verify_attempts >= v_max and j.item_key is not null and j.workflow_id is not null then
    perform onboarding_set_item(j.workflow_id, j.item_key, 'manual_required', jsonb_build_object('ui_job_id', j.id, 'verify', 'gave_up'), null, 'auto',
                                '登録の操作は終わりましたが、スマレジの値を読み直して照合できませんでした。スマレジの画面で値を確認してください');
    begin
      perform onboarding_add_manual_step(j.workflow_id, '照合できなかった設定をスマレジの画面で確認（' || j.kind || '）', left(coalesce(p_note, '読み直しに失敗'), 200));
    exception when others then null; end;
    v_escalated := true;
  end if;
  return jsonb_build_object('ok', true, 'verified', j.verified, 'verify_attempts', j.verify_attempts, 'escalated', v_escalated);
end $$;
revoke all on function public.ui_job_verify_record(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.ui_job_verify_record(uuid, boolean, text) to service_role;

-- 成功で終わったのに、照合の結果がまだ無いジョブ（10 分以上たったもの・直近 3 日・5 回未満）
create or replace function public.ui_job_unverified()
returns setof uuid language sql security definer set search_path = public as $$
  select id from ui_automation_jobs
   where status = 'success' and not dry_run and item_key is not null and workflow_id is not null and verified is null
     and verify_attempts < 5 and finished_at < now() - interval '10 minutes' and finished_at > now() - interval '3 days'
   order by finished_at limit 20;
$$;
revoke all on function public.ui_job_unverified() from public, anon, authenticated;
grant execute on function public.ui_job_unverified() to service_role;

-- 照合のやり直し（10 分おき）。該当が無ければ何もしない
create or replace function public.ui_job_verify_sweep()
returns integer language plpgsql security definer set search_path = public as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/onboarding-notify';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_id uuid; n int := 0;
begin
  if not exists (select 1 from ui_job_unverified()) then return 0; end if;
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'ui_job_verify_sweep: app_secrets.notify_slack_secret が未設定'; return 0; end if;
  for v_id in select * from ui_job_unverified() loop
    perform net.http_post(url := c_fn,
      headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
      body := jsonb_build_object('op', 'ui_job_result', 'job_id', v_id, 'sweep', true), timeout_milliseconds := 60000);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.ui_job_verify_sweep() from public, anon, authenticated;
grant execute on function public.ui_job_verify_sweep() to service_role;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'ui-job-verify-sweep') then perform cron.unschedule('ui-job-verify-sweep'); end if;
  perform cron.schedule('ui-job-verify-sweep', '*/10 * * * *', 'select public.ui_job_verify_sweep()');
end $$;
