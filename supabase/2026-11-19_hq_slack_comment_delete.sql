-- 2026-11-19 担当B（社長の承認）— Slack のスレッドのコメントの［🗑 削除］で、管理システムのコメントも消す（新しい関数 hq_slack_comment_delete・既存の関数には触れない）
-- 消せる人: コメントを書いた本人・マスター・CEO・HQ。添付（hq_task_comment_files）の記録は、コメントと一緒に消える（ファイル本体は置き場に残る）。service_role 専用。
-- 戻し方: drop function if exists public.hq_slack_comment_delete(text, uuid);
create or replace function public.hq_slack_comment_delete(p_slack_user_id text, p_comment uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_u users%rowtype; v_c hq_task_comments%rowtype;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  select u.* into v_u from user_slack s join users u on u.id = s.user_id where s.slack_user_id = p_slack_user_id and u.is_active;
  if v_u.id is null then return jsonb_build_object('ok', false, 'message', 'Slack が管理システムに紐づいていません'); end if;
  select * into v_c from hq_task_comments where id = p_comment;
  if v_c.id is null then return jsonb_build_object('ok', true, 'already', true, 'message', 'すでに削除されています'); end if;
  if not (v_c.created_by = v_u.id or v_u.is_master or v_u.role in ('CEO', 'HQ')) then
    return jsonb_build_object('ok', false, 'message', '削除できるのは、書いた本人と本部だけです');
  end if;
  delete from hq_task_comments where id = v_c.id;
  insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_c.task_id, v_u.id, 'comment', 'コメントを削除（Slack）');
  return jsonb_build_object('ok', true, 'task_id', v_c.task_id);
end $$;
revoke all on function public.hq_slack_comment_delete(text, uuid) from public, anon, authenticated;
grant execute on function public.hq_slack_comment_delete(text, uuid) to service_role;
