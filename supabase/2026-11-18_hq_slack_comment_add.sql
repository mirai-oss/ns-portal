-- 2026-11-18 担当B — Slack のチャンネルのカードの［💬 コメント］から、本部タスクにコメントを入れる DB 関数（新規 1 本。既存の関数・テーブルは変えない）
-- 【仕組み】Slack の本人（user_slack で紐づけ済み）として、画面と同じ権限判定（hq_task_visible）を通してから hq_task_comments に入れる。
--   @名前 を書くとその人へ通知（hq_notify_comment が、アプリ内通知・Slack の個人 DM を出す。既存の仕組みのまま）。service_role 専用
-- 【rollback】drop function if exists public.hq_slack_comment_add(text, uuid, text);
create or replace function public.hq_slack_comment_add(p_slack_user_id text, p_task uuid, p_body text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid; v_body text := btrim(coalesce(p_body, '')); v_ment uuid[]; v_cid uuid; v_old text; v_title text;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  select u.id into v_uid from user_slack s join users u on u.id = s.user_id where s.slack_user_id = p_slack_user_id and u.is_active;
  if v_uid is null then return jsonb_build_object('ok', false, 'message', 'Slack が管理システムに紐づいていません'); end if;
  if length(v_body) < 1 then return jsonb_build_object('ok', false, 'message', 'コメントを入力してください'); end if;
  if length(v_body) > 2000 then return jsonb_build_object('ok', false, 'message', 'コメントは 2000 文字までです'); end if;

  v_old := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);
  if not coalesce(hq_task_visible(p_task), false) then
    perform set_config('request.jwt.claims', coalesce(v_old, ''), true);
    return jsonb_build_object('ok', false, 'message', 'このタスクにはコメントできません');
  end if;
  select coalesce(array_agg(u.id), '{}') into v_ment from users u
   where u.is_active and u.id <> v_uid and length(btrim(u.name)) > 0 and position('@' || btrim(u.name) in v_body) > 0;
  insert into hq_task_comments(task_id, created_by, body, mentions) values (p_task, v_uid, v_body, v_ment) returning id into v_cid;
  perform set_config('request.jwt.claims', coalesce(v_old, ''), true);

  begin perform hq_notify_comment(v_cid); exception when others then null; end;   -- 通知に失敗してもコメントは入る
  select title into v_title from hq_tasks where id = p_task;
  return jsonb_build_object('ok', true, 'comment_id', v_cid, 'title', v_title);
end;
$function$;
revoke all on function public.hq_slack_comment_add(text, uuid, text) from public, anon, authenticated;
grant execute on function public.hq_slack_comment_add(text, uuid, text) to service_role;

select (select count(*) from pg_proc where proname = 'hq_slack_comment_add' and pronamespace = 'public'::regnamespace) as 関数の本数;
