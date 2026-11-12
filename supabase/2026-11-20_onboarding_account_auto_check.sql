-- =============================================================
-- 入社登録の自動化の残り（その 3）: 本人アカウントの登録を、1 日 1 回、自動で確かめる（2026-11-12 ユーザー指示「Slack連携・本人アカウントの再判定を完成」）
--   いま: 本人がスマレジのアカウントを登録したかは、人が「スマレジ照合」を押したときだけ読みに行く（API に項目が無く、管理画面を読む必要がある）。
--   これから: 手続き中の入社登録で、スマレジ従業員登録が済んでいて「本人アカウント」が未完了なら、見回り（10 分おき）が 1 日 1 回、読み取りの依頼を待ち行列に入れる。
--     ★ 読むだけ（スマレジには何も書かない）。設定 app_settings.onboarding_alerts.account_ui_read_enabled が true のときだけ動く（いまは false ＝ 何もしない）。
--     実際に読むのは Mac の自動操作。「登録済み」と読めたら、今ある仕組み（onboarding-notify op=ui_job_result）が項目を完了にする。
--   既存の表・関数は変えない（関数 1 つを足し、見回り onboarding_auto_sweep に 1 行）。2026-11-19_onboarding_commute_one_step.sql のあとに適用する。
--   戻し方: 2026-11-20_onboarding_account_auto_check_rollback.sql
-- =============================================================

create or replace function public.onboarding_account_auto_check(p_workflow uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare wf onboarding_workflows%rowtype; v_old text; r jsonb; v_ok boolean := false;
begin
  if coalesce((select value ->> 'account_ui_read_enabled' from app_settings where key = 'onboarding_alerts'), 'false') <> 'true' then return false; end if;   -- 設定が切れている: 何もしない
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null or wf.status <> 'registering' or wf.user_id is null then return false; end if;
  if not exists (select 1 from onboarding_items i where i.workflow_id = wf.id and i.item_key = 'smaregi_staff' and i.state = 'completed') then return false; end if;
  if not exists (select 1 from onboarding_items i where i.workflow_id = wf.id and i.item_key = 'smaregi_account' and i.state not in ('completed', 'cancelled')) then return false; end if;
  -- 1 日 1 回まで（待っている・動いている依頼があるあいだも入れない）
  if exists (select 1 from ui_automation_jobs j where j.workflow_id = wf.id and j.kind = 'smaregi_read'
              and (j.status in ('pending', 'running') or j.created_at > now() - interval '20 hours')) then return false; end if;
  v_old := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  begin
    r := ui_job_enqueue(wf.id, 'smaregi_read', '{"read": ["account_status"]}'::jsonb, null, true);
    v_ok := coalesce((r ->> 'ok')::boolean, false);
  exception when others then
    raise warning 'onboarding_account_auto_check: %', sqlerrm;
  end;
  perform set_config('request.jwt.claims', coalesce(v_old, ''), true);
  return v_ok;
end $$;

revoke all on function public.onboarding_account_auto_check(uuid) from public, anon, authenticated;
grant execute on function public.onboarding_account_auto_check(uuid) to service_role;

-- 見回りに 1 行足す
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
end $$;
