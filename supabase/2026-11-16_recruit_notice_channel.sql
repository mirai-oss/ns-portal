-- 採用管理の通知の宛先を「採用-応募通知」（C0CFXJZ3V7B）にする（2026-11-12 ユーザー決定。本番には同日に反映済み。この文は記録と再現のため）
--   最初に指定された C0CGY7PCFM4 は、通知アプリ（N-Style 通知Bot）から見えなかった（未参加）。通知アプリが参加している「採用-応募通知」を使う、と決定。
--   通知のスイッチ（app_settings.recruit_slack.enabled）は変えない（false のまま）。
update slack_channels set slack_channel_id = 'C0CFXJZ3V7B', display_name = '#採用-応募通知', updated_at = now()
 where channel_key = 'hr.saiyo' and slack_channel_id is distinct from 'C0CFXJZ3V7B';
