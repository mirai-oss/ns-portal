-- 2026-11-22 担当B（社長の決め）— 勤怠確認の「最初のメンション」を、指定した店舗だけ「本人＋指定した人」にする
--  対象店舗: 鶏武者 新横浜・鶏武者 川崎店・黒霧屋 新横浜 ／ 指定した人: 鍋倉（チーム長）。社長・店舗の担当は付けない
--  リマインド（スレッドの⏰）と、ほかの店舗は、今までどおり。設定の置き場所: app_settings.attendance_alert_mention（無ければ全店舗が今までどおり）
-- 【戻し方】delete from app_settings where key = 'attendance_alert_mention';
insert into app_settings(key, value)
select 'attendance_alert_mention', jsonb_build_object('overrides', jsonb_build_array(jsonb_build_object(
  'store_ids', (select jsonb_agg(id) from stores where name in ('鶏武者 新横浜', '鶏武者 川崎店', '黒霧屋 新横浜') and is_active),
  'user_ids',  (select jsonb_agg(id) from users where name = '鍋倉巧' and is_active))))
on conflict (key) do update set value = excluded.value;

-- 確認（3 店舗・1 人が入っていれば OK）
select jsonb_array_length(value -> 'overrides' -> 0 -> 'store_ids') as 店舗数, jsonb_array_length(value -> 'overrides' -> 0 -> 'user_ids') as 人数
  from app_settings where key = 'attendance_alert_mention';
