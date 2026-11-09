-- スマレジ管理画面への自動書き込みスイッチを OFF に戻す（2026-11-09）
update app_settings set value = value || '{"smaregi_write_enabled": false}' where key = 'commute_rules';
select key, value ->> 'smaregi_write_enabled' as smaregi_write_enabled from app_settings where key = 'commute_rules';
