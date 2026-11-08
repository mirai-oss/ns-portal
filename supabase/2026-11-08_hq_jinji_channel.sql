-- 2026-11-08 本部向け通知（給与明細の照合結果・賃金設定の申請・退職申請）の送り先を Slack の人事チャンネル C0CFE1Y9HC7（channel_key hq.jinji）へ
--   LINE への送信は止める（CEO/HQ は Slack 紐づけで LINE 連携が外れている）。Slack 上で処理する仕組みは後日。
update public.slack_channels
   set slack_channel_id = 'C0CFE1Y9HC7', display_name = '#本部-人事', purpose = '本部向け人事通知: 給与明細の照合結果・賃金設定の申請・退職申請・Slack 未連携リマインド（2026-11-08）', is_active = true, updated_at = now()
 where channel_key = 'hq.jinji';
insert into public.slack_channels (channel_key, slack_channel_id, display_name, purpose, is_active)
select 'hq.jinji', 'C0CFE1Y9HC7', '#本部-人事', '本部向け人事通知（2026-11-08）', true
 where not exists (select 1 from public.slack_channels where channel_key = 'hq.jinji');
