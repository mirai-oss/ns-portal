-- 2026-11-18 担当B（社長の承認「全員にして」）— 本部タスクのメンション Slack DM を、Slack 紐づけ済みの全員に広げる
-- 【変更】app_settings.hqtask_comment_slack_dm の only_user_ids を空（[]）にする＝全員が対象（enabled=true のまま）。関数・Chatwork・アプリ内通知は不変
-- 【対象】メンションされた人のうち Slack 紐づけ済みの人だけ（紐づけ無しの人には何も起きない）。自分自身のメンションは送らない。同じコメント×同じ相手は1回
-- 【戻し方】update app_settings set value = jsonb_set(value, '{only_user_ids}', jsonb_build_array((select id::text from users where role = 'CEO' and is_active))) where key = 'hqtask_comment_slack_dm';（社長1人だけに戻る）／完全に止めるなら enabled を false に
do $$
declare v jsonb;
begin
  select value into v from app_settings where key = 'hqtask_comment_slack_dm';
  if v is null then raise exception '停止: スイッチ（hqtask_comment_slack_dm）がありません'; end if;
  if coalesce((v ->> 'enabled')::boolean, false) is not true then raise exception '停止: enabled が true ではありません'; end if;
  update app_settings set value = jsonb_set(value, '{only_user_ids}', '[]'::jsonb), updated_at = now() where key = 'hqtask_comment_slack_dm';
end $$;
select value ->> 'enabled' as enabled, jsonb_array_length(value -> 'only_user_ids') as 対象を絞っている人数_0なら全員 from app_settings where key = 'hqtask_comment_slack_dm';
