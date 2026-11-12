-- =============================================================
-- 入社登録の自動化の残り（その 1）: Web 明細・メール登録を自動で待ち行列に入れる／Slack 連携の再判定（2026-11-12 ユーザー指示「入社登録を最終完了まで自動化」）
--   いま:
--     ・個別 Web 給与明細の有効化とメールアドレスの登録は、自動操作のプログラムはあるが、待ち行列に入れる入口が無い（人がスマレジの画面で入力して ✓）。
--     ・入社登録の「Slack 連携」は、入社の時点で連携済みのときしか完了にならない（あとから Slack に参加しても完了に変わらない）。
--   これから（10 分おきの見回り onboarding_auto_sweep）:
--     ・手続き中の入社登録で、スマレジ従業員登録が済んでいて、Web 明細／メールが「未」なら、自動で待ち行列に入れる。
--       ★ スマレジへの自動書き込みのスイッチ（app_settings.commute_rules.smaregi_write_enabled）が false のあいだは、何もしない（今までどおり、人の手作業）。
--       Web 明細は「表示する」。メールは、本人が入社フォームで入れたメールアドレス（users.email）。形が正しくないときは入れない（人の確認へ）。
--     ・Slack と紐づいたら（user_slack に行がある）、「Slack 連携」を完了にする。
--     ・何か変わったら、Slack の入社登録の表示を描き直す（onboarding-notify op=refresh）。
--   自動操作のあとの完了は、今までどおり「スマレジを読み直して一致したときだけ」（2026-11-15_ui_job_verify_before_complete.sql）。
--   既存の表・関数は変えない（関数 3 つと定期実行 1 つを足すだけ）。未承認の賃金・既存のスイッチには触れない。
--   戻し方: 2026-11-18_onboarding_auto_steps_rollback.sql
-- =============================================================

-- 1 件の入社登録について、待ち行列に入れられるものを入れる。戻り値は、何をしたか（氏名・メールアドレスは入れない）
create or replace function public.onboarding_auto_enqueue(p_workflow uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare wf onboarding_workflows%rowtype; v_old text; v_mail text; r jsonb; v_out jsonb := '{}'::jsonb; v_changed boolean := false;
begin
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null or wf.status <> 'registering' or wf.user_id is null then return jsonb_build_object('ok', true, 'skipped', 'not_registering'); end if;
  if not exists (select 1 from onboarding_items where workflow_id = wf.id and item_key = 'smaregi_staff' and state = 'completed') then
    return jsonb_build_object('ok', true, 'skipped', 'staff_not_ready');
  end if;
  if coalesce((select value ->> 'smaregi_write_enabled' from app_settings where key = 'commute_rules'), 'false') <> 'true' then
    return jsonb_build_object('ok', true, 'skipped', 'write_disabled');   -- スイッチが切れている: 何もしない
  end if;
  -- ここから先は自動処理として動く（待ち行列の関数は service_role か、ログインしている本部の人しか呼べないため）。終わったら元に戻す
  v_old := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  begin
    if exists (select 1 from onboarding_items where workflow_id = wf.id and item_key = 'web_payslip' and state = 'pending') then
      r := ui_job_enqueue(wf.id, 'smaregi_payslip', '{"flag": true}'::jsonb, null, false);
      v_out := v_out || jsonb_build_object('web_payslip', case when (r ->> 'ok')::boolean then 'queued' else coalesce(r ->> 'error', 'failed') end);
      v_changed := v_changed or coalesce((r ->> 'ok')::boolean, false);
    end if;
    if exists (select 1 from onboarding_items where workflow_id = wf.id and item_key = 'email' and state = 'pending') then
      select nullif(btrim(u.email), '') into v_mail from users u where u.id = wf.user_id;
      if v_mail is not null and v_mail ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
        r := ui_job_enqueue(wf.id, 'smaregi_email', jsonb_build_object('mail', v_mail), null, false);
        v_out := v_out || jsonb_build_object('email', case when (r ->> 'ok')::boolean then 'queued' else coalesce(r ->> 'error', 'failed') end);
        v_changed := v_changed or coalesce((r ->> 'ok')::boolean, false);
      else
        v_out := v_out || jsonb_build_object('email', 'no_valid_address');   -- メールアドレスが無い・形が正しくない: 入れない（人の確認へ）
      end if;
    end if;
  exception when others then
    v_out := v_out || jsonb_build_object('error', left(sqlerrm, 200));
  end;
  perform set_config('request.jwt.claims', coalesce(v_old, ''), true);
  return jsonb_build_object('ok', true, 'changed', v_changed) || v_out;
end $$;

-- Slack と紐づいていたら、入社登録の「Slack 連携」を完了にする
create or replace function public.onboarding_slack_link_refresh(p_workflow uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare wf onboarding_workflows%rowtype; v_old text; v_done boolean := false;
begin
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null or wf.status <> 'registering' or wf.user_id is null then return false; end if;
  if not exists (select 1 from onboarding_items where workflow_id = wf.id and item_key = 'slack_link' and state in ('pending', 'failed', 'retry_wait', 'manual_required')) then return false; end if;
  if not exists (select 1 from user_slack k where k.user_id = wf.user_id and nullif(k.slack_user_id, '') is not null) then return false; end if;
  v_old := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  begin
    perform onboarding_set_item(wf.id, 'slack_link', 'completed', jsonb_build_object('source', 'user_slack', 'checked_at', now()), null, 'auto', null);
    v_done := true;
  exception when others then
    raise warning 'onboarding_slack_link_refresh: %', sqlerrm;
  end;
  perform set_config('request.jwt.claims', coalesce(v_old, ''), true);
  return v_done;
end $$;

-- 見回り（10 分おき）: 手続き中の入社登録を順に見る。変わったものがあれば、Slack の表示を描き直す
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

revoke all on function public.onboarding_auto_enqueue(uuid), public.onboarding_slack_link_refresh(uuid), public.onboarding_auto_sweep() from public, anon, authenticated;
grant execute on function public.onboarding_auto_enqueue(uuid), public.onboarding_slack_link_refresh(uuid), public.onboarding_auto_sweep() to service_role;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'onboarding-auto-sweep') then perform cron.unschedule('onboarding-auto-sweep'); end if;
  perform cron.schedule('onboarding-auto-sweep', '*/10 * * * *', 'select public.onboarding_auto_sweep()');
end $$;
