-- 2026-11-18 担当B（社長の承認）— Slack の DM スレッドでの返信は、@ を書かなくても「もとのコメントを書いた人」へ自動でメンションする
-- 【変更】関数 hqtask_comment_reply_post だけ（返信コメントの本文の先頭に「@名前 」を足し、mentions にもその人を入れる。すでに本文で @ 指定済みなら足さない／自分宛ては足さない）
-- 【安全】いまの関数の中身の指紋（md5）が想定と違えば、何も変えずに止まる。設定（スイッチ・対象者）は触らない
-- 【rollback】2026-11-18_hqtask_comment_reply.sql の関数定義をもう一度実行
do $do$
declare v_md5 text;
begin
  select md5(prosrc) into v_md5 from pg_proc where proname = 'hqtask_comment_reply_post' and pronamespace = 'public'::regnamespace;
  if v_md5 is null then raise exception '停止: 関数がありません'; end if;
  if v_md5 = '937dd5b01b0c0ae508405770df1c36c7' then raise notice 'すでに新しい版です（何もしません）'; return; end if;
  if v_md5 <> '906ec22a360abc88dd5a47e5f180d359' then raise exception '停止: 関数の中身が想定と違います（%）。変えずに止めました', v_md5; end if;
  execute $q$
create or replace function public.hqtask_comment_reply_post(p_event_id text, p_channel text, p_thread_ts text, p_slack_user text, p_body text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_cfg jsonb; v_map record; v_slack text; v_body text := btrim(coalesce(p_body, ''));
  v_ment uuid[]; v_cid uuid; v_title text; v_old text; v_auth uuid; v_aname text;
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
  -- 2026-11-18 返信の相手（このスレッドのもとになったコメントを書いた人）へは、@ を書かなくても自動でメンションする
  select created_by into v_auth from hq_task_comments where id = v_map.comment_id;
  if v_auth is not null and v_auth <> v_map.user_id and not (v_auth = any(v_ment)) then
    select btrim(name) into v_aname from users where id = v_auth and is_active and length(btrim(name)) > 0;
    if v_aname is not null then v_ment := v_ment || v_auth; v_body := '@' || v_aname || ' ' || v_body; end if;
  end if;
  insert into hq_task_comments(task_id, created_by, body, mentions) values (v_map.task_id, v_map.user_id, v_body, v_ment) returning id into v_cid;
  perform set_config('request.jwt.claims', coalesce(v_old, ''), true);

  begin perform hq_notify_comment(v_cid); exception when others then null; end;   -- アプリ内通知・メンション相手への Slack DM（失敗しても投稿は成功）
  select title into v_title from hq_tasks where id = v_map.task_id;
  return jsonb_build_object('ok', true, 'code', 'posted', 'comment_id', v_cid, 'task_id', v_map.task_id, 'user_id', v_map.user_id, 'title', v_title);
end;
$function$
$q$;
  revoke all on function public.hqtask_comment_reply_post(text, text, text, text, text) from public, anon, authenticated;
  grant execute on function public.hqtask_comment_reply_post(text, text, text, text, text) to service_role;
end $do$;
