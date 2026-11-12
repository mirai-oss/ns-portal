-- 2026-11-20_onboarding_account_auto_check.sql の戻し（見回りを 11-19 の定義に戻し、足した関数を外す）
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

drop function if exists public.onboarding_account_auto_check(uuid);
