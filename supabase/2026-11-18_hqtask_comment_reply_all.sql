-- 2026-11-18 担当B（社長の承認「スレッド返信を全員に広げて」）— Slack の DM スレッドへの返信 → タスクのコメント を、Slack 紐づけ済みの全員に広げる
-- 【変更】app_settings.hqtask_comment_reply の only_user_ids を空（[]）にする＝全員が対象（enabled=true のまま）。関数は不変
-- 【戻し方】update app_settings set value = jsonb_set(value, '{only_user_ids}', jsonb_build_array((select id::text from users where role = 'CEO' and is_active))) where key = 'hqtask_comment_reply';
do $$
declare v jsonb;
begin
  select value into v from app_settings where key = 'hqtask_comment_reply';
  if v is null then raise exception '停止: スイッチ（hqtask_comment_reply）がありません'; end if;
  if coalesce((v ->> 'enabled')::boolean, false) is not true then raise exception '停止: enabled が true ではありません'; end if;
  update app_settings set value = jsonb_set(value, '{only_user_ids}', '[]'::jsonb), updated_at = now() where key = 'hqtask_comment_reply';
end $$;
select value from app_settings where key = 'hqtask_comment_reply';
