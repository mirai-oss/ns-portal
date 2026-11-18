-- 2026-11-18 担当B（社長の依頼）— Slack「#本部-チャット」を、「＋ タスクを作る」ボタンの置き場所として登録する（slack_channels に 1 行）
-- 【チャンネルID】社長が、下の 'ここにチャンネルIDを貼る' の部分を自分で置き換える（IDは担当Bにも渡さず・ファイル・コミットにも書かない）
-- 【安全ガード】形が ID でなければ停止（何も変更しない）。同じ ID が自動登録（auto.…）で入っていれば、その行は無効にして hq.chat に一本化する（押したチャンネルから親投稿のキーを引くときに2行ヒットしないため）
-- 【影響】登録だけ。外へは何も出ない。【rollback】delete from slack_channels where channel_key = 'hq.chat';（auto.… を無効にした場合は is_active = true に戻す）
do $$
declare v_id text := 'ここにチャンネルIDを貼る';
begin
  if v_id !~ '^C[A-Z0-9]{8,}$' then raise exception '停止: チャンネルIDが貼られていません（「ここにチャンネルIDを貼る」を、SlackのチャンネルIDに置き換えてください）'; end if;
  update slack_channels set is_active = false, updated_at = now() where slack_channel_id = v_id and channel_key like 'auto.%';
  insert into slack_channels (channel_key, slack_channel_id, display_name, purpose, is_active)
  values ('hq.chat', v_id, '#本部-チャット', '本部のチャット。「＋ タスクを作る」ボタンを置く（2026-11-18）', true)
  on conflict (channel_key) do update set slack_channel_id = excluded.slack_channel_id, display_name = excluded.display_name, purpose = excluded.purpose, is_active = true, updated_at = now();
end $$;
select channel_key as キー, display_name as 表示名, is_active as 有効, (slack_channel_id is not null and slack_channel_id <> '') as チャンネルID設定済み from slack_channels where channel_key = 'hq.chat';
