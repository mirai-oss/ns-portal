-- 2026-11-18 担当B（社長の依頼・承認待ち）— 「#本部-チャット」に「＋ タスクを作る」ボタンを 1 通置く（外へ出る投稿）
-- 【前提】①slack_channels に hq.chat 登録済み ②Slack でそのチャンネルにアプリを参加させ済み（未参加だと channel_not_found で失敗し、同じ日は再投稿できない記録があるため、先に参加）
-- 【やること】EF hq-task-reminders の op=post_create_button に channel_key=hq.chat を渡す（合言葉は DB の app_secrets から読む・値は出さない）。create_enabled が true のときだけ置かれる
-- 【影響】そのチャンネルにボタンの投稿が 1 通出る。押すと入力フォームが開く（親投稿＋スレッドが残る作り）。【戻し方】Slack でその投稿を削除する
do $$
declare v_secret text; v_req bigint;
begin
  if not exists (select 1 from slack_channels where channel_key = 'hq.chat' and is_active and coalesce(slack_channel_id, '') <> '') then
    raise exception '停止: hq.chat が登録されていません（先に登録のSQLを実行してください）';
  end if;
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise exception '停止: 合言葉（notify_slack_secret）が未設定です'; end if;
  select net.http_post(
    url := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/hq-task-reminders',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr', 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'post_create_button', 'channel_key', 'hq.chat'),
    timeout_milliseconds := 30000
  ) into v_req;
  raise notice 'ボタンの投稿を依頼しました（請求番号 %）。Slack の #本部-チャット を見てください', v_req;
end $$;
