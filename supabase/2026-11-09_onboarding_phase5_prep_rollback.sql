-- =============================================================
-- 切り戻し: 2026-11-09_onboarding_phase5_prep.sql（データ保全版・2026-11-09）
--   消すもの: 設定の追記キー・trigger 関数・error_kind の 'not_supported' 選択肢（該当行があれば残すために null にはしない＝先に 'other' へ寄せる）・ビューの security_invoker
--   残すもの: onboarding_workflows.last_stale_alert_at 列（値も残す。害なし）・onboarding_events の記録（commute.auto_judged / person.contact / account.checked / stale.alerted）
--   cron 'onboarding-stale-alert' は本 SQL では登録していない（登録してあれば先に select cron.unschedule('onboarding-stale-alert');）
-- =============================================================
update app_settings set value = value - 'auto_approve' where key = 'commute_rules';
update app_settings set value = value - 'enabled' - 'person_notify_enabled' - 'account_ui_read_enabled' - 'person_channel_order'
   || jsonb_build_object('note', '停滞アラート（Phase 5 で cron 化）') where key = 'onboarding_alerts';
drop function if exists public.onboarding_stale_alert_trigger();
update public.ui_automation_jobs set error_kind = 'other' where error_kind = 'not_supported';
alter table public.ui_automation_jobs drop constraint if exists ui_automation_jobs_error_kind_check;
alter table public.ui_automation_jobs add constraint ui_automation_jobs_error_kind_check
  check (error_kind is null or error_kind in ('auth_expired','screen_changed','save_failed','verify_mismatch','timeout','not_found','other'));
alter view public.recruit_funnel_v reset (security_invoker);
alter view public.onboarding_stale_v reset (security_invoker);
