-- ============================================================
-- 2026-11-18 担当B（社長承認）— 第2段階: Slack の DM スレッドに返信すると、そのタスクのコメントとして書き込まれる（DB 側）
-- 【状態】事前報告（未適用・社長の承認待ち）。前提: 2026-11-18_hq_notify_comment_dm_thread.sql 適用済み（対応表 hqtask_comment_slack_sent に DM の ts がある）
-- 【仕組み】Edge Function（slack-events の分岐→_shared/hqtask-reply.ts）が受けた DM の返信を、この関数 hqtask_comment_reply_post に渡す。
--   ①イベントIDで二重処理を防ぐ ②スイッチ app_settings.hqtask_comment_reply（既定 enabled=false・最初は社長だけ）③対応表で「どのタスクの通知スレッドか」を引く（無ければ何もしない）
--   ④返信した Slack ユーザーが、その通知の受け取り本人であること ⑤本人としての権限確認（画面と同じ hq_task_visible・素通りしない）⑥コメント登録（@名前 は本人以外の有効ユーザーの名前に一致したものをメンションとして扱う）⑦hq_notify_comment（アプリ内通知・メンション相手への Slack DM）
-- 【保存・ログ】コメント本文はコメントとして保存するだけ（ログ・イベント表には本文を残さない）
-- 【rollback】スイッチを false にする／drop function hqtask_comment_reply_post(text,text,text,text,text); drop table hqtask_reply_events;
-- ============================================================
create table if not exists hqtask_reply_events (
  event_id text primary key,
  created_at timestamptz not null default now()
);
alter table hqtask_reply_events enable row level security;
revoke all on hqtask_reply_events from public, anon, authenticated;

insert into app_settings (key, value)
select 'hqtask_comment_reply', jsonb_build_object('enabled', false, 'only_user_ids', jsonb_build_array(c.id::text),
         'note', 'Slack の DM スレッドへの返信を、本部タスクのコメントとして取り込む。enabled=true で有効。only_user_ids が空でなければその人だけ（到着確認用）')
  from (select id from users where role = 'CEO' and is_active) c
 where (select count(*) from users where role = 'CEO' and is_active) = 1
on conflict (key) do nothing;

create or replace function public.hqtask_comment_reply_post(p_event_id text, p_channel text, p_thread_ts text, p_slack_user text, p_body text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_cfg jsonb; v_map record; v_slack text; v_body text := btrim(coalesce(p_body, ''));
  v_ment uuid[]; v_cid uuid; v_title text; v_old text;
begin
  if coalesce(p_event_id, '') = '' or coalesce(p_channel, '') = '' or coalesce(p_thread_ts, '') = '' or coalesce(p_slack_user, '') = '' then
    return jsonb_build_object('ok', false, 'code', 'bad_args');
  end if;
  insert into hqtask_reply_events(event_id) values (p_event_id) on conflict do nothing;
  if not found then return jsonb_build_object('ok', true, 'code', 'duplicate'); end if;

  select value into v_cfg from app_settings where key = 'hqtask_comment_reply';
  if coalesce((v_cfg ->> 'enabled')::boolean, false) is not true then return jsonb_build_object('ok', true, 'code', 'off'); end if;

  select * into v_map from hqtask_comment_slack_sent where slack_channel = p_channel and slack_ts = p_thread_ts limit 1;
  if v_map.comment_id is null or v_map.task_id is null then return jsonb_build_object('ok', true, 'code', 'no_thread'); end if;
  if coalesce(jsonb_array_length(v_cfg -> 'only_user_ids'), 0) > 0 and not ((v_cfg -> 'only_user_ids') ? v_map.user_id::text) then
    return jsonb_build_object('ok', true, 'code', 'off');
  end if;

  select slack_user_id into v_slack from user_slack where user_id = v_map.user_id;
  if v_slack is distinct from p_slack_user then return jsonb_build_object('ok', true, 'code', 'not_owner'); end if;
  if length(v_body) < 1 then return jsonb_build_object('ok', true, 'code', 'empty'); end if;
  if length(v_body) > 2000 then return jsonb_build_object('ok', false, 'code', 'too_long', 'user_id', v_map.user_id); end if;

  -- 本人としての権限確認（画面と同じ判定を、本人の claims で通す。このトランザクションの中だけ）
  v_old := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_map.user_id::text, 'role', 'authenticated')::text, true);
  if not coalesce(hq_task_visible(v_map.task_id), false) then
    perform set_config('request.jwt.claims', coalesce(v_old, ''), true);
    return jsonb_build_object('ok', false, 'code', 'denied', 'user_id', v_map.user_id);
  end if;

  select coalesce(array_agg(u.id), '{}') into v_ment from users u
   where u.is_active and u.id <> v_map.user_id and length(btrim(u.name)) > 0 and position('@' || btrim(u.name) in v_body) > 0;
  insert into hq_task_comments(task_id, created_by, body, mentions) values (v_map.task_id, v_map.user_id, v_body, v_ment) returning id into v_cid;
  perform set_config('request.jwt.claims', coalesce(v_old, ''), true);

  begin perform hq_notify_comment(v_cid); exception when others then null; end;   -- アプリ内通知・メンション相手への Slack DM（失敗しても投稿は成功）
  select title into v_title from hq_tasks where id = v_map.task_id;
  return jsonb_build_object('ok', true, 'code', 'posted', 'comment_id', v_cid, 'task_id', v_map.task_id, 'user_id', v_map.user_id, 'title', v_title);
end;
$function$;
revoke all on function public.hqtask_comment_reply_post(text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.hqtask_comment_reply_post(text, text, text, text, text) to service_role;

select (select count(*) from pg_proc where proname = 'hqtask_comment_reply_post' and pronamespace = 'public'::regnamespace) as 関数の本数,
       (select value ->> 'enabled' from app_settings where key = 'hqtask_comment_reply') as スイッチenabled,
       (select jsonb_array_length(value -> 'only_user_ids') from app_settings where key = 'hqtask_comment_reply') as 対象人数;
