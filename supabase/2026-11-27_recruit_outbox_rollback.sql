-- 2026-11-27_recruit_outbox.sql を外す  ★実行は別途承認
--   ふだん「止める」ときは、これではなく  select recruit_actions_cfg_set(false, 'dry', 'dry');  （スイッチを閉じるだけ。何も消えない）
--   先に、Edge Function recruit-action を止める（または、呼ぶ側のボタンのスイッチを切る）こと。
--   送信箱（applicant_outbox）は、1 行でもあれば消さずに残す（送信の履歴のため）。既存の表・関数・トリガー・line-webhook には触れない。

drop function if exists public.recruit_send_finish(uuid, text, text, jsonb);
drop function if exists public.recruit_send_begin(uuid, text, text, text, uuid, text, text);
drop function if exists public.recruit_send_check(uuid, uuid);
drop function if exists public.recruit_actions_cfg_set(boolean, text, text);
drop function if exists public.recruit_actions_cfg();

delete from app_settings where key = 'recruit_actions';

do $$
begin
  if to_regclass('public.applicant_outbox') is null then return; end if;
  if exists (select 1 from public.applicant_outbox) then
    raise notice '送信箱（applicant_outbox）に行があるため、表は残しました';
  else
    drop table public.applicant_outbox;
  end if;
end $$;
