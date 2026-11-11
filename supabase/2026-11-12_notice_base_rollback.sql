-- 2026-11-12_notice_base.sql を外す  ★実行は別途承認
--   どの通知もまだこの部品を使っていない状態（種類の形式の版が全部 1）であること。使い始めたあとは、先に版を 1 に戻す。
--   未連携の確認タスク（本部タスク）は消さない（控えの表だけ消える）。
do $$
begin
  if to_regclass('public.notice_types') is not null and exists (select 1 from notice_types where format_version <> 1) then raise exception '共通の形（版 2）に切り替えた通知の種類があります。先に版を 1 に戻してください'; end if;
end $$;
drop function if exists notice_case_upsert(text, text, text, jsonb);
drop function if exists notice_unlinked_task_sync(uuid[], text, boolean);
drop function if exists notice_mention_targets(text, text, uuid, uuid[]);
drop function if exists notice_settings_set(uuid, uuid[], uuid[]);
drop table if exists notice_unlinked_tasks;
drop table if exists notice_cases;
drop table if exists notice_mention_rules;
drop table if exists notice_types;
delete from app_settings where key = 'notice';
-- slack_policy（金額を出さないチャンネルの設定）は、Edge Function が読むので消さない。空に戻すときは: update app_settings set value = '{"hide_amount_channels": []}' where key = 'slack_policy';
