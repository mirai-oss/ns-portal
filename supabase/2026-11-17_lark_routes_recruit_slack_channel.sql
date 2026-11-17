-- 2026-11-17 担当B（社長の指示）— 通知ルートの Slack 行『求人メッセージ通知（Slack）』『求人応募通知（Slack）』の宛先を #採用-応募通知（channel_key=hr.saiyo）にそろえる
-- 【社長の指示】2つとも、Slack チャンネル ID C0CFXJZ3V7B に流す。slack_channels で hr.saiyo がその ID であることを確認してから切り替える（違えば停止）
-- 【変えるのは宛先だけ】有効／無効・対象イベントは今のまま（求人応募=ON・求人メッセージ=OFF）。新しい採用カードが同じチャンネルに既に出るため、求人応募を ON のままにすると同じ応募が2回出る可能性（画面で OFF にできる）
-- 【rollback】update lark_routes set webhook_url = 'hq.jinji' where kind = 'slack' and name in ('求人メッセージ通知（Slack）', '求人応募通知（Slack）');
do $$
declare n int;
begin
  select count(*) into n from lark_routes where kind = 'slack' and name in ('求人メッセージ通知（Slack）', '求人応募通知（Slack）');
  if n <> 2 then raise exception '停止: 対象の通知先が % 行です（2行のはず）', n; end if;
  if not exists (select 1 from slack_channels where channel_key = 'hr.saiyo' and slack_channel_id = 'C0CFXJZ3V7B' and is_active) then
    raise exception '停止: hr.saiyo のチャンネルIDが C0CFXJZ3V7B ではありません。何も変更していません';
  end if;
  update lark_routes set webhook_url = 'hr.saiyo' where kind = 'slack' and name in ('求人メッセージ通知（Slack）', '求人応募通知（Slack）');
end $$;
select name, is_active as 有効, webhook_url as 宛先キー, events as 対象イベント from lark_routes where kind = 'slack' and name in ('求人メッセージ通知（Slack）', '求人応募通知（Slack）') order by name;
