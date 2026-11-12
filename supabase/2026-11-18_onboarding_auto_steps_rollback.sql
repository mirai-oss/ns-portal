-- 2026-11-18_onboarding_auto_steps.sql の戻し（足した関数 3 つと定期実行を外す。ほかの表・関数には触れない）
do $$ begin
  if exists (select 1 from cron.job where jobname = 'onboarding-auto-sweep') then perform cron.unschedule('onboarding-auto-sweep'); end if;
end $$;
drop function if exists public.onboarding_auto_sweep();
drop function if exists public.onboarding_slack_link_refresh(uuid);
drop function if exists public.onboarding_auto_enqueue(uuid);
