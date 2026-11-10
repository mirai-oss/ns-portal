-- 振込 CSV 出力を再開する。全画面（nippo・振込画面・ポータル承認画面）の更新と動作確認が済んでから実行する
-- 手順: docs/手順書_ステップ3-4_本番切り替え_2026-11-11.md
update app_settings set value = value || '{"transfer_export_paused": false}'::jsonb where key = 'employee_change';
select value ->> 'transfer_export_paused' as paused from app_settings where key = 'employee_change';
