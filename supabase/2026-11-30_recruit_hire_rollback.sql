-- 2026-11-30_recruit_hire.sql を外す  ★実行は別途承認
--   先に、Edge Function（recruit-action・slack-interact・recruit-notify）を、採用のボタンと op=hire を持たない版に戻すこと。
--   既存の採用の処理（hire_applicant など）・招待・入社登録には触れない。操作の記録（applicant_ops の op = hire の行）は残る。
drop function if exists public.recruit_invite_sent(uuid, uuid);
drop function if exists public.recruit_hire(uuid, text, uuid[], text, uuid, text, jsonb, text);
drop function if exists public.recruit_hire_info(uuid, uuid);
update app_settings set value = value - 'hire_shain_allow_master' where key = 'recruit_actions' and value ? 'hire_shain_allow_master';
