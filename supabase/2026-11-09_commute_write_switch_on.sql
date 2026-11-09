-- スマレジ管理画面への自動書き込みスイッチを ON（立会いの書き込みテスト用・2026-11-09）。戻すときは同名の _off.sql
update app_settings set value = value || '{"smaregi_write_enabled": true}' where key = 'commute_rules';
select key, value ->> 'smaregi_write_enabled' as smaregi_write_enabled from app_settings where key = 'commute_rules';
