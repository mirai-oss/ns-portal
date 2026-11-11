-- 賃金の取り込み前チェックを無効に戻す（すでに記録した未承認の変更は残る。記録がある人は、無効に戻しても保留のまま）
update app_settings set value = value || '{"wage_import_precheck": false}'::jsonb where key = 'employee_change';
