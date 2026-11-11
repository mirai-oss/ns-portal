-- 2026-11-15_monitor_watch.sql の戻し（監視の相互確認をやめる。ほかの表・関数・定期実行には触れない）
do $$ begin
  if exists (select 1 from cron.job where jobname = 'monitor-check') then perform cron.unschedule('monitor-check'); end if;
end $$;
drop function if exists public.monitor_check(boolean);
drop function if exists public.monitor_last_ok(text);
drop function if exists public.monitor_beat(text);
drop table if exists public.monitor_watch;
