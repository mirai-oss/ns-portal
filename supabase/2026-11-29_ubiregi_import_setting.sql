-- 2026-11-29 ユビレジの売上をクラウドから書き込む関数（ubiregi-sales-import）の対象店舗と開始日（担当D・社長依頼）。
--   店舗を足すときはここに1件足す。戻し方: delete from app_settings where key = 'ubiregi_import';（関数は何も書けなくなる）
insert into app_settings (key, value) values ('ubiregi_import', jsonb_build_object('stores', jsonb_build_object('伊達の宴 国分町店', '2026-11-01')))
on conflict (key) do update set value = excluded.value;
