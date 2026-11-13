-- 2026-11-28_recruit_interview.sql を外す  ★実行は別途承認
--   先に、Edge Function recruit-action を、面接の操作を呼ばない版に戻す（または、ボタンのスイッチを切る）こと。いまの画面の確定（set_interview）には触れない。
--   操作の記録（applicant_ops）の列 steps は、残す（消すと、面接の操作の履歴の中身が無くなるため）。結果の値（processing・partial）も、使っている行があれば残す。

drop function if exists public.recruit_interview_finish(uuid, text, text);
drop function if exists public.recruit_interview_save(uuid, text, text, boolean);
drop function if exists public.recruit_interview_step(uuid, text, jsonb);
drop function if exists public.recruit_interview_begin(uuid, text, text, uuid, text, timestamptz, text, text, boolean, jsonb);

do $$
begin
  if to_regclass('public.applicant_ops') is null then return; end if;
  if exists (select 1 from public.applicant_ops where result in ('processing', 'partial')) then
    raise notice '操作の記録に processing / partial の行があるため、結果の値はそのままにしました';
  else
    alter table public.applicant_ops drop constraint if exists applicant_ops_result_check;
    alter table public.applicant_ops add constraint applicant_ops_result_check check (result in ('done', 'noop', 'conflict', 'denied', 'failed'));
  end if;
end $$;
