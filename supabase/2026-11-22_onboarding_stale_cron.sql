-- =============================================================
-- 入社登録: 止まっている入社登録の見つけ出しを、定期実行にする（2026-11-12・★本番未適用。適用は別途承認）
--   いま: 止まっている項目を見つけて知らせる仕組み（Edge Function onboarding-notify の op=stale_alert と、呼び出し役の関数 onboarding_stale_alert_trigger）は
--         出来ているが、定期実行が登録されていない。設定 app_settings.onboarding_alerts.enabled も false。
--   これから: 1 時間に 1 回（毎時 10 分）、呼び出し役の関数を動かす。
--     ★ 設定 onboarding_alerts.enabled が false のあいだは、候補を数えるだけで、Slack には何も送らない（今までどおり）。
--       知らせ始めるのは、設定を true にしたとき（別途承認）。そのときの決まり（今ある作りのまま）:
--         48 時間以上止まっている項目がある入社登録だけ／同じ入社登録は 24 時間に 1 回まで／22 時〜 8 時は送らない／入社登録のスレッドに 1 件＋その日のまとめ 1 件（同じ日は 1 件にまとまる）。
--   あわせて、監視の一覧（monitor_watch）に、入社登録の見回り 2 つ（onboarding-auto-sweep・ui-job-verify-sweep）とこの定期実行を足す
--     （止まったら、毎時 20 分の見張り monitor-check が気づけるようにする）。
--   既存の表・関数は変えない（定期実行 1 つと、監視の一覧の 3 行を足すだけ）。
--   戻し方: 2026-11-22_onboarding_stale_cron_rollback.sql
-- =============================================================
do $$ begin
  if exists (select 1 from cron.job where jobname = 'onboarding-stale-alert') then perform cron.unschedule('onboarding-stale-alert'); end if;
  perform cron.schedule('onboarding-stale-alert', '10 * * * *', 'select public.onboarding_stale_alert_trigger()');
end $$;

insert into public.monitor_watch(key, label, source, cron_jobname, max_silence_minutes, enabled, note)
values
  ('cron:onboarding-auto-sweep',  '入社登録の見回り（自動の待ち行列入り・再判定）', 'cron', 'onboarding-auto-sweep',  60,  true, '10 分おき。60 分'),
  ('cron:ui-job-verify-sweep',    '自動操作の照合の見回り',                       'cron', 'ui-job-verify-sweep',    60,  true, '10 分おき。60 分'),
  ('cron:onboarding-stale-alert', '止まっている入社登録の見つけ出し',             'cron', 'onboarding-stale-alert', 180, true, '1 時間に 1 回。3 時間')
on conflict (key) do nothing;
