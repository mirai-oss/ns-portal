-- =============================================================
-- 入社登録ワークフロー Phase 5 の土台（2026-11-09・★ 本番未適用。適用は中山さんの承認後）
--   内容（すべて追加のみ。既存の行・列・関数は書き換えない）:
--     1) app_settings.commute_rules に auto_approve（自動承認。既定 enabled=false・shadow=true＝記録だけ）を追記
--     2) app_settings.onboarding_alerts に enabled=false（停滞アラート）・person_notify_enabled=false（本人への自動連絡）・account_ui_read_enabled=false を追記
--     3) onboarding_workflows.last_stale_alert_at（停滞アラートの最終送信）
--     4) 関数 onboarding_stale_alert_trigger()（pg_cron から EF onboarding-notify op=stale_alert を呼ぶ。cron の登録はコメントアウト＝承認後に手で）
--     5) ui_automation_jobs.error_kind の選択肢に 'not_supported' を追加（画面に項目が無いとき）
--     6) recruit_funnel_v / onboarding_stale_v を security_invoker に（呼び出し元の RLS で絞る）
--   切り戻し: 下部のコメント参照（データは消えない）
-- =============================================================

-- 1) 自動承認（既定 OFF・記録だけ）。有効化は update app_settings set value = jsonb_set(value, '{auto_approve,enabled}', 'true') where key='commute_rules';
update app_settings
   set value = value || jsonb_build_object('auto_approve', coalesce(value -> 'auto_approve', '{}'::jsonb) || jsonb_build_object(
                 'enabled', coalesce((value -> 'auto_approve' ->> 'enabled')::boolean, false),
                 'shadow', coalesce((value -> 'auto_approve' ->> 'shadow')::boolean, true),
                 'max_oneway_yen', coalesce((value -> 'auto_approve' ->> 'max_oneway_yen')::int, 1500),
                 'allow_bus', coalesce((value -> 'auto_approve' ->> 'allow_bus')::boolean, false),
                 'allowed_methods', coalesce(value -> 'auto_approve' -> 'allowed_methods', '["train"]'::jsonb),
                 'require_home_station', coalesce((value -> 'auto_approve' ->> 'require_home_station')::boolean, true),
                 'require_exact_match', coalesce((value -> 'auto_approve' ->> 'require_exact_match')::boolean, false),
                 'note', '自動承認（2026-11-09）。enabled=true で「申請額 ≦ API 算出額・片道 max_oneway_yen 以内・バスなし・通勤手段 allowed_methods・最寄り駅登録済み」の通常申請を自動承認。shadow=true は記録だけ。有効化は中山さんの承認後'))
 where key = 'commute_rules';

-- 2) 停滞アラート・本人連絡・アカウント確認（UI 読み取り）の有効フラグ（既定 false）
update app_settings
   set value = value || jsonb_build_object(
                 'enabled', coalesce((value ->> 'enabled')::boolean, false),
                 'person_notify_enabled', coalesce((value ->> 'person_notify_enabled')::boolean, false),
                 'account_ui_read_enabled', coalesce((value ->> 'account_ui_read_enabled')::boolean, false),
                 'person_channel_order', coalesce(value -> 'person_channel_order', '["slack","line"]'::jsonb),
                 'note', '停滞アラート（enabled）・本人への自動連絡（person_notify_enabled。false なら Slack スレッドに文面を出すだけ）・本人アカウント登録の UI 読み取りジョブ（account_ui_read_enabled）。quiet_from〜quiet_to（JST）は送らない。stale_hours 以上止まった項目を repeat_hours おきに通知')
 where key = 'onboarding_alerts';

-- 3) 停滞アラートの最終送信時刻
alter table public.onboarding_workflows add column if not exists last_stale_alert_at timestamptz;

-- 5) UI ジョブのエラー種類に not_supported（画面に該当項目が無い＝手動対応へ）
alter table public.ui_automation_jobs drop constraint if exists ui_automation_jobs_error_kind_check;
alter table public.ui_automation_jobs add constraint ui_automation_jobs_error_kind_check
  check (error_kind is null or error_kind in ('auth_expired','screen_changed','save_failed','verify_mismatch','timeout','not_found','not_supported','other'));

-- 6) 集計ビューを呼び出し元の権限で評価（recruit_funnel_v は applicants の RLS（can_see_applicant）を通す＝店舗限定の担当者に全店の件数が見えないように。onboarding_stale_v は hq_can_manage）
alter view public.recruit_funnel_v set (security_invoker = true);
alter view public.onboarding_stale_v set (security_invoker = true);

-- 4) pg_cron → EF onboarding-notify op=stale_alert（slack_remind_employees_trigger と同じ作法。合言葉は app_secrets.notify_slack_secret）
create or replace function public.onboarding_stale_alert_trigger()
returns void
language plpgsql security definer set search_path to 'public', 'net', 'extensions'
as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/onboarding-notify';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_req bigint;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'onboarding_stale_alert_trigger: notify_slack_secret 未設定'; return; end if;
  select net.http_post(
    url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'stale_alert', 'trigger', 'pg_cron'),
    timeout_milliseconds := 120000
  ) into v_req;
end $$;
revoke all on function public.onboarding_stale_alert_trigger() from public, anon, authenticated;

-- cron の登録（★ 承認後に手で実行。EF 側も onboarding_alerts.enabled=true でないと送らない＝二重の安全）:
--   select cron.schedule('onboarding-stale-alert', '0 0 * * *', $$select public.onboarding_stale_alert_trigger()$$);   -- 00:00 UTC = 09:00 JST
--   止める: select cron.unschedule('onboarding-stale-alert');

-- 切り戻し（データは消えない）:
--   update app_settings set value = value - 'auto_approve' where key='commute_rules';
--   update app_settings set value = value - 'enabled' - 'person_notify_enabled' - 'account_ui_read_enabled' - 'person_channel_order' where key='onboarding_alerts';
--   drop function if exists public.onboarding_stale_alert_trigger();
--   alter table public.onboarding_workflows drop column if exists last_stale_alert_at;   -- 列は残しても害はない
