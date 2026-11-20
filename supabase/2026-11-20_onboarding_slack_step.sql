-- 入社登録: 「Slack 連携」を本部タスクの工程にし、連携されたら自動で完了にする（2026-11-20・社長の指示）
--   ・onboarding_ensure_slack_step（新規）: 手続き中・タスク未完了の入社に、工程「Slack連携を確認」を足して項目に結びつける
--   ・onboarding_set_item: slack_link が完了したら、結びついた工程を完了にする（email と同じ作法）
--   ・onboarding_auto_sweep: 10 分おきの見回りで ensure を呼ぶ（Slack 連携の再判定・Playwright の待ち行列入れはこれまでどおり。slack_link の状態に左右されない）
--   戻し方: 2026-11-20_onboarding_slack_step_rollback.sql（本番の旧定義を戻す）
create or replace function public.onboarding_ensure_slack_step(p_workflow uuid)
returns void language plpgsql security definer set search_path = public as $$
declare wf onboarding_workflows%rowtype; it onboarding_items%rowtype; v_step uuid; v_assignee uuid; v_due date;
  c_title constant text := 'Slack連携を確認（本人がSlackに参加）';
begin
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null or wf.status <> 'registering' or wf.hq_task_id is null then return; end if;
  if not exists (select 1 from hq_tasks t where t.id = wf.hq_task_id and t.deleted_at is null and t.status <> 'done') then return; end if;
  select * into it from onboarding_items where workflow_id = wf.id and item_key = 'slack_link';
  if it.id is null or it.hq_task_step_id is not null then return; end if;
  select id into v_step from hq_task_steps where task_id = wf.hq_task_id and title = c_title limit 1;
  if v_step is null then
    select assignee_id, due_date into v_assignee, v_due from hq_task_steps where task_id = wf.hq_task_id and assignee_id is not null order by sort_order limit 1;
    insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date, procedure_note)
    values (wf.hq_task_id, c_title, v_assignee, 50, 'step', v_due, '本人がSlackに参加すると、自動で完了になります（人の操作は不要。参加の案内は自動で送られます）。')
    returning id into v_step;
    insert into hq_task_activity(task_id, actor_id, kind, detail) values (wf.hq_task_id, null, 'comment', '入社ワークフロー: 「Slack連携」の工程を追加（連携されると自動で完了）');
  end if;
  update onboarding_items set hq_task_step_id = v_step, updated_at = now() where id = it.id;
  if it.state = 'completed' then update hq_task_steps set completed_at = coalesce(completed_at, now()) where id = v_step and completed_at is null; end if;
end $$;

CREATE OR REPLACE FUNCTION public.onboarding_set_item(p_workflow uuid, p_item text, p_state text, p_payload jsonb DEFAULT NULL::jsonb, p_actor uuid DEFAULT NULL::uuid, p_via text DEFAULT 'auto'::text, p_error text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  it onboarding_items%rowtype; v_before jsonb; v_actor uuid; wf onboarding_workflows%rowtype; v_total int; v_done int; v_all_done boolean;
begin
  if auth.uid() is not null then
    v_actor := public.onboarding_resolve_actor(null);
  elsif public.onboarding_is_service() then
    v_actor := p_actor;                                 -- 自動処理は null のこともある
  else
    raise exception '認証が必要です';
  end if;
  if p_state not in ('pending','running','completed','retry_wait','manual_required','manual_running','cancelled','failed') then
    raise exception '不正な状態です: %', p_state;
  end if;
  select * into wf from onboarding_workflows where id = p_workflow for update;
  if wf.id is null then return jsonb_build_object('ok', false, 'error', 'ワークフローが見つかりません'); end if;
  select * into it from onboarding_items where workflow_id = p_workflow and item_key = p_item for update;
  if it.id is null then return jsonb_build_object('ok', false, 'error', '項目が見つかりません: ' || p_item); end if;
  v_before := jsonb_build_object('state', it.state, 'attempts', it.attempts, 'payload', it.payload, 'last_error', it.last_error);

  update onboarding_items set
    state = p_state,
    attempts = case when p_state = 'running' then attempts + 1 else attempts end,
    payload = coalesce(p_payload, payload),
    last_error = case when p_state in ('failed','retry_wait','manual_required') then coalesce(p_error, last_error) when p_state = 'completed' then null else last_error end,
    completed_at = case when p_state = 'completed' then coalesce(completed_at, now()) else null end,
    -- 完了のしかた（手動 ✓ と区別する）: payload.verified が true ならスマレジ照合済み、false ならスマレジ保存のみ、それ以外はシステム判定
    completion_source = case when p_state <> 'completed' then null
                             when coalesce(p_payload, payload) ->> 'verified' = 'true' then 'smaregi_verified'
                             when coalesce(p_payload, payload) ->> 'verified' = 'false' then 'smaregi_unverified'
                             else 'auto' end,
    updated_at = now()
  where id = it.id returning * into it;

  insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after, payload)
  values (p_workflow, p_item, 'item.state', v_actor, coalesce(p_via, 'auto'), v_before,
          jsonb_build_object('state', it.state, 'attempts', it.attempts, 'payload', it.payload, 'last_error', it.last_error), p_payload);

  -- 本部タスク工程②のチェック（自動処理の完了で ✓。人が二重に作業しなくてよいように）
  if p_state = 'completed' and it.hq_checklist_item_id is not null then
    update hq_step_checklist_items set checked_at = coalesce(checked_at, now()), checked_by = coalesce(checked_by, v_actor) where id = it.hq_checklist_item_id;
    if it.hq_task_step_id is not null then
      select count(*), count(*) filter (where checked_at is not null) into v_total, v_done from hq_step_checklist_items where step_id = it.hq_task_step_id;
      if v_total > 0 and v_total = v_done then
        update hq_task_steps set completed_at = coalesce(completed_at, now()), completed_by = coalesce(completed_by, v_actor) where id = it.hq_task_step_id and completed_at is null;
      end if;
    end if;
    if wf.hq_task_id is not null then
      insert into hq_task_activity(task_id, step_id, actor_id, kind, detail)
      values (wf.hq_task_id, it.hq_task_step_id, v_actor, 'comment', '入社ワークフロー: ' || p_item || ' が完了（' || coalesce(p_via, 'auto') || '）');
    end if;
  end if;
  -- 工程①（メール）は項目だけで工程そのものを完了にする
  if p_state = 'completed' and p_item = 'email' and it.hq_task_step_id is not null then
    update hq_task_steps set completed_at = coalesce(completed_at, now()), completed_by = coalesce(completed_by, v_actor) where id = it.hq_task_step_id and completed_at is null;
  end if;
  -- 工程（Slack 連携）は項目だけで工程そのものを完了にする（2026-11-20）
  if p_state = 'completed' and p_item = 'slack_link' and it.hq_task_step_id is not null then
    update hq_task_steps set completed_at = coalesce(completed_at, now()), completed_by = coalesce(completed_by, v_actor) where id = it.hq_task_step_id and completed_at is null;
  end if;
  -- 賃金が入ったら、LINE 返信用の依頼（hr_wage_requests）を閉じる（二重登録防止・段階的切替の一部）
  if p_state = 'completed' and p_item = 'wage' and wf.user_id is not null then
    update hr_wage_requests set status = 'done', done_at = coalesce(done_at, now()), done_by = coalesce(done_by, v_actor), workflow_id = coalesce(workflow_id, wf.id)
     where user_id = wf.user_id and status = 'pending';
  end if;

  -- 完了判定（Phase 1 は「全項目 completed」。cancelled 項目は対象外。入社登録完了と初回勤務は別物＝ここでは勤務を見ない）
  select bool_and(state = 'completed') into v_all_done from onboarding_items where workflow_id = p_workflow and state <> 'cancelled';
  if coalesce(v_all_done, false) and wf.status = 'registering' then
    update onboarding_workflows set status = 'completed', completed_at = now(), updated_at = now() where id = p_workflow;
    insert into onboarding_events(workflow_id, kind, actor_id, via) values (p_workflow, 'workflow.completed', v_actor, 'auto');
  elsif not coalesce(v_all_done, false) and wf.status = 'completed' then
    -- 完了後に項目が戻された: 入社登録完了の履歴（completed_at）は残し、status だけ戻す
    update onboarding_workflows set status = 'registering', updated_at = now() where id = p_workflow;
  end if;
  update onboarding_workflows set updated_at = now() where id = p_workflow;

  return jsonb_build_object('ok', true, 'item', to_jsonb(it), 'workflow_status', (select status from onboarding_workflows where id = p_workflow));
end $function$
;

CREATE OR REPLACE FUNCTION public.onboarding_auto_sweep()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/onboarding-notify';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  w record; r jsonb; v_secret text; n int := 0; n_changed int := 0; v_ch boolean;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  for w in select id from onboarding_workflows where status = 'registering' order by created_at limit 50 loop
    n := n + 1; v_ch := false;
    begin
      perform onboarding_ensure_slack_step(w.id);     -- 本部タスクに「Slack 連携」の工程を足す（2026-11-20）
      if onboarding_slack_link_refresh(w.id) then v_ch := true; end if;
      perform onboarding_commute_auto_search(w.id);   -- 経路の検索を自動で始める（1 回だけ。表示の描き直しは検索の側が行う）
      perform onboarding_account_auto_check(w.id);    -- 本人アカウントの登録を 1 日 1 回読む（読むだけ。結果は自動操作の側が返す）
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
end $function$
;
