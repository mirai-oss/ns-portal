-- 2026-11-26_recruit_action_base.sql を外す  ★実行は別途承認
--   ふだん「止める」ときは、これではなく、次のどちらか（何も消えない）:
--     ・Slack のボタンを消す           … select recruit_actions_set(false);
--     ・初期の割り当てを止める         … app_settings.recruit_assign の 4 つの値を null に戻す
--   これは、足したトリガー・関数・設定を取り除く。既存の表の列・既存の関数・既存のトリガー（applicant_auto_assign・recruit_notice_* など）には触れない。
--   先に、Edge Function（slack-interact・recruit-notify）を、この SQL の関数を呼ばない版に戻しておくこと（呼ぶ版のままだと、ボタンを押したときにエラーになる。スイッチが false ならボタンは出ない）。
--   操作の記録（applicant_ops）は、1 行でもあれば消さずに残す（履歴のため）。担当者の設定は、値が入っていれば消さずに残す。

-- 1) 足したトリガーを外す（表は変えない）
drop trigger if exists applicant_auto_assign_default on public.applicants;

-- 2) 足した関数を消す
drop function if exists public.trg_applicant_assign_default();
drop function if exists public.recruit_unhandled_mark(uuid, timestamptz);
drop function if exists public.recruit_unhandled_targets(timestamptz, boolean);
drop function if exists public.recruit_assignee_candidates(uuid, uuid);
drop function if exists public.recruit_assignee_set(uuid, uuid, uuid, text, uuid, text, text);
drop function if exists public.recruit_default_assignee(text);
drop function if exists public.recruit_assign_user(text);
drop function if exists public.recruit_kind_of(text);
drop function if exists public.recruit_op_log(uuid, text, uuid, text, text, jsonb, jsonb, text, text, text, timestamptz);
drop function if exists public.recruit_actions_set(boolean);

-- 3) 設定: ボタンのスイッチのキーを外す（無いのと false は同じ動き）。担当者の設定は、値が全部 null のときだけ消す
update app_settings set value = value - 'actions_enabled' where key = 'recruit_slack' and value ? 'actions_enabled';
delete from app_settings
 where key = 'recruit_assign'
   and coalesce(value ->> 'part_main', '') = '' and coalesce(value ->> 'part_backup', '') = ''
   and coalesce(value ->> 'employee_main', '') = '' and coalesce(value ->> 'unknown_confirm', '') = '';

-- 4) 操作の記録の表: 空のときだけ消す
do $$
begin
  if to_regclass('public.applicant_ops') is null then return; end if;
  if exists (select 1 from public.applicant_ops) then
    raise notice '操作の記録（applicant_ops）に行があるため、表は残しました';
  else
    drop table public.applicant_ops;
  end if;
end $$;

-- 確認用（読むだけ）
-- select proname from pg_proc where pronamespace = 'public'::regnamespace and (proname ~ '^recruit_(assign|op_log|kind_of|unhandled|default_assignee|actions_set)' or proname = 'trg_applicant_assign_default');   -- 0 行
-- select tgname from pg_trigger where tgrelid = 'public.applicants'::regclass and tgname = 'applicant_auto_assign_default';   -- 0 行
