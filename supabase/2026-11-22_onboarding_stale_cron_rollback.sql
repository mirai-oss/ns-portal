-- 2026-11-22_onboarding_stale_cron.sql の戻し（足した定期実行と、監視の一覧の 3 行を外す。ほかには触れない）
do $$ begin
  if exists (select 1 from cron.job where jobname = 'onboarding-stale-alert') then perform cron.unschedule('onboarding-stale-alert'); end if;
end $$;
delete from public.monitor_watch where key in ('cron:onboarding-auto-sweep', 'cron:ui-job-verify-sweep', 'cron:onboarding-stale-alert');
