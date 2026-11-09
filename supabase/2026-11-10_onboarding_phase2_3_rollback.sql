-- =============================================================
-- 2026-11-10 Phase 2/3 の切り戻し（データ保全版）: 仕組み（RPC・ビュー）だけ外し、表・行・列・設定は残す
--   Phase 1（2026-11-09）には触れない。通知だけ止めるなら app_settings.commute_rules.smaregi_write_enabled=false（既定）で足りる
--   実行: python3 scripts/apply_sql.py supabase/2026-11-10_onboarding_phase2_3_rollback.sql [--dry-run]
-- =============================================================
update public.app_settings set value = coalesce(value, '{}'::jsonb) || jsonb_build_object('smaregi_write_enabled', false, 'rolled_back_at', now()), updated_at = now() where key = 'commute_rules';
-- 未完了ジョブは取り消し（Mac が拾わないように）
update public.ui_automation_jobs set status = 'cancelled', finished_at = now(), updated_at = now() where status in ('pending','claimed','running');
drop view if exists public.onboarding_stale_v;
drop view if exists public.recruit_funnel_v;
drop function if exists public.onboarding_cancel(uuid, text, text, uuid);
drop function if exists public.onboarding_add_manual_step(uuid, text, text);
drop function if exists public.ui_job_finish(uuid, boolean, jsonb, text, text, text, boolean);
drop function if exists public.ui_job_heartbeat(uuid, text);
drop function if exists public.ui_job_claim(text);
drop function if exists public.onboarding_set_commute_setting(uuid, text, text, date, text, integer, jsonb, integer, text, text, uuid);
drop function if exists public.ui_job_enqueue(uuid, text, jsonb, uuid, boolean);
drop function if exists public.onboarding_import_commute_from_extra(uuid);
drop function if exists public.onboarding_commute_decide(uuid, text, integer, text, uuid);
drop function if exists public.onboarding_save_commute(uuid, text, text, integer, boolean, text, text, uuid);
-- 残すもの（意図的）: 表 employee_commute / employee_commute_settings / employee_tax_settings / ui_automation_jobs / ui_automation_job_log とその行、
--   applicants の exit_* 列、app_settings の commute_rules / onboarding_alerts。完全に消すときは先に archive スキーマへ写す（Phase 1 の rollback と同じ作法）
select '切り戻し（データ保全版）: Phase 2/3 の RPC とビューを外しました。表・行・列は残っています' as note;
