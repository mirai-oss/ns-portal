-- 2026-11-19 担当B（社長の承認）— 採用ボタン復活 ③: 送信スイッチを ON にする（本物の応募者のカードに、LINE返信・面接・採用のボタンが出る）
-- 【これで変わること】本物の応募者へ、Slack のボタンから、実際に LINE が届き（line_mode=live）、面接の確定でカレンダーに予定が作られる（calendar_mode=live）ようになる。
-- 【安全】LINE とカレンダーが、どちらも本番モードであることを確かめてから行う。
-- 【戻し方】update app_settings set value = value || '{"send_enabled":false}'::jsonb where key = 'recruit_actions';（すぐに止められる。応募者へ送るボタンは、テスト用の応募者だけに戻る）
do $do$
declare v jsonb;
begin
  select value into v from app_settings where key = 'recruit_actions';
  if coalesce(v ->> 'line_mode', '') <> 'live' or coalesce(v ->> 'calendar_mode', '') <> 'live' then raise exception '停止: LINE とカレンダーが、どちらも本番モード（live）ではありません'; end if;
  update app_settings set value = value || '{"send_enabled":true}'::jsonb, updated_at = now() where key = 'recruit_actions';
end $do$;
