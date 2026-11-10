-- 振込 CSV 出力を一時停止する（切り替え作業・緊急時）。ステップ 3 の SQL（2026-11-10_pay_change_requests.sql）適用後に使える
-- 停止中: 出力の記録を受け付けない・振込口座を画面から直接読めない（古い画面を開き直しても CSV を作れない）。登録データは変わらない
update app_settings set value = value || '{"transfer_export_paused": true}'::jsonb where key = 'employee_change';
select value ->> 'transfer_export_paused' as paused from app_settings where key = 'employee_change';
