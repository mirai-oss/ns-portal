-- 2026-11-17 担当B（社長の指示）— 通知ルートの Slack 行『求人メッセージ通知（Slack）』『求人応募通知（Slack）』の宛先を #採用-応募通知（channel_key=hr.saiyo）にそろえる
-- 【社長の指示】2つとも、社長が指定した Slack チャンネル（slack_channels の hr.saiyo = #採用-応募通知）に流す。ID の一致確認は実行前に担当Bが読み取りで済ませてあり、この SQL・コミットには ID を書かない（Slack の ID は docs・リポジトリに書かない決まり）
-- 【変えるのは宛先だけ】有効／無効・対象イベントは今のまま（求人応募=ON・求人メッセージ=OFF）。新しい採用カードが同じチャンネルに既に出るため、求人応募を ON のままにすると同じ応募が2回出る可能性（画面で OFF にできる）
-- 【rollback】update lark_routes set webhook_url = 'hq.jinji' where kind = 'slack' and name in ('求人メッセージ通知（Slack）', '求人応募通知（Slack）');
do $$
declare n int;
begin
  select count(*) into n from lark_routes where kind = 'slack' and name in ('求人メッセージ通知（Slack）', '求人応募通知（Slack）');
  if n <> 2 then raise exception '停止: 対象の通知先が % 行です（2行のはず）', n; end if;
  if not exists (select 1 from slack_channels where channel_key = 'hr.saiyo' and coalesce(slack_channel_id, '') <> '' and is_active) then
    raise exception '停止: slack_channels に hr.saiyo（有効・チャンネル設定済み）がありません。何も変更していません';
  end if;
  update lark_routes set webhook_url = 'hr.saiyo' where kind = 'slack' and name in ('求人メッセージ通知（Slack）', '求人応募通知（Slack）');
end $$;
select name, is_active as 有効, webhook_url as 宛先キー, events as 対象イベント from lark_routes where kind = 'slack' and name in ('求人メッセージ通知（Slack）', '求人応募通知（Slack）') order by name;
