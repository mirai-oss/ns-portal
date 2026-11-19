-- 2026-11-19 担当B（社長の承認）— 採用ボタン復活 ②: カレンダーを本番モードにして、テスト用の応募者で確認する
-- 【安全】送信スイッチ（send_enabled）が OFF のままであることを確かめてから行う。OFF のあいだは、面接の確定ができるのは、テスト用の応募者（answers._test=true）だけ（DB の関数が断る）。
-- 【やること】設定 recruit_actions.calendar_mode を 'live' にする（LINE の設定 line_mode と、送信スイッチ send_enabled は、そのまま）。
--   本番モードのあいだ、テスト用の応募者の面接を Slack で確定すると、共有の Google カレンダー（管理システムの画面の面接 Meet と同じもの）に、予定が実際に作られる。予定は、面接の取り消しで消せる。
-- 【戻し方】update app_settings set value = value || '{"calendar_mode":"dry"}'::jsonb where key = 'recruit_actions';
do $do$
begin
  if coalesce((select value ->> 'send_enabled' from app_settings where key = 'recruit_actions'), 'false') <> 'false' then raise exception '停止: 送信スイッチが OFF ではありません'; end if;
  update app_settings set value = value || '{"calendar_mode":"live"}'::jsonb, updated_at = now() where key = 'recruit_actions';
end $do$;
