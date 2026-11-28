-- 2026-11-22 担当B（社長の決め）— 勤怠確認の「最初のメンション」を、指定した店舗だけ「本人＋指定した人」にする
--  対象店舗: 鶏武者 新横浜・鶏武者 川崎店・黒霧屋 新横浜 ／ 指定した人: 対象店舗のチーム長 1 名。社長・店舗の担当は付けない
--  ※公開リポジトリなので氏名は書かない（11/28 に置き換え）。実行し直すときだけ【指定する人の氏名】を入れる。入れ忘れた場合は何も変わらない
--  リマインド（スレッドの⏰）と、ほかの店舗は、今までどおり。設定の置き場所: app_settings.attendance_alert_mention（無ければ全店舗が今までどおり）
-- 【戻し方】delete from app_settings where key = 'attendance_alert_mention';
insert into app_settings(key, value)
select 'attendance_alert_mention', jsonb_build_object('overrides', jsonb_build_array(jsonb_build_object(
  'store_ids', (select jsonb_agg(id) from stores where name in ('鶏武者 新横浜', '鶏武者 川崎店', '黒霧屋 新横浜') and is_active),
  'user_ids',  (select jsonb_agg(id) from users where name = '【指定する人の氏名】' and is_active))))
 where exists (select 1 from users where name = '【指定する人の氏名】' and is_active)
on conflict (key) do update set value = excluded.value;

-- 確認（3 店舗・1 人が入っていれば OK）
select jsonb_array_length(value -> 'overrides' -> 0 -> 'store_ids') as 店舗数, jsonb_array_length(value -> 'overrides' -> 0 -> 'user_ids') as 人数
  from app_settings where key = 'attendance_alert_mention';
