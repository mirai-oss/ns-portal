-- 2026-11-19 担当B（社長の承認）— 次の担当者への通知を ON にする（設定 app_settings.hq_task_slack の next_notice_enabled だけを true にする）
-- 戻し方: update app_settings set value = value || '{"next_notice_enabled": false}'::jsonb where key = 'hq_task_slack';
update app_settings set value = value || '{"next_notice_enabled": true}'::jsonb where key = 'hq_task_slack';
