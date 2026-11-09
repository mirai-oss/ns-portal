-- 切替 B（2026-11-09・ユーザー指示「Slack の通知はボタン付きの最初の 1 通だけに」）: 従来の「賃金登録をお願いします」文面を止め、親メッセージ（ボタン付き）だけにする
update public.app_settings set value = value || '{"enabled": true, "legacy_wage_text": false}'::jsonb, updated_at = now() where key = 'onboarding_slack';
select key, value ->> 'enabled' as enabled, value ->> 'legacy_wage_text' as legacy_wage_text from public.app_settings where key = 'onboarding_slack';
-- 戻す: update public.app_settings set value = value || '{"legacy_wage_text": true}'::jsonb where key = 'onboarding_slack';
