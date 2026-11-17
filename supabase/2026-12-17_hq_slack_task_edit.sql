-- Slack から本部タスクを編集する（2026-11-17）。親投稿（1 行）＋スレッドの詳細カード＋「編集」ボタン。
--   hq_slack_task_log に、親投稿の場所（チャンネル・ts・台帳 id）と、スレッドのカードの台帳 id を足す。
--   hq_slack_task_get: 編集フォームの初期値（service_role 専用）。
--   hq_slack_task_update: 編集の保存。直せる人＝作成者・本部・社長・マスター。Slack で作ったタスクだけ・未完了だけ。
--     直すもの: やること・法人・詳細・注意事項・最重要・期限（日付＋時刻）・担当者（未完了の工程すべて）・工程の追加（消す・並べ替えはしない）。
-- 戻し方: drop function public.hq_slack_task_update(...); drop function public.hq_slack_task_get(uuid); drop function public.hq_slack_task_card_set(uuid, text, text, uuid, uuid); alter table hq_slack_task_log drop column ...
-- ★本番の hq_task_step_before_update を取得し、権限の 1 行だけ「Slack の編集の中（service_role かつ hq.slack_edit=1）なら通す」に変えた（ほかは無変更）。
CREATE OR REPLACE FUNCTION public.hq_task_step_before_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
begin
  if not (hq_can_manage() or hq_feature_allowed('steps') or (hq_slack_is_service() and coalesce(current_setting('hq.slack_edit', true), '') = '1')) then   -- 2026-11-17: Slack の編集（hq_slack_task_update の中だけ）
    if new.task_id <> old.task_id or new.title <> old.title or new.kind <> old.kind
       or coalesce(new.assignee_id::text,'') <> coalesce(old.assignee_id::text,'')
       or coalesce(new.assignee_ids,'{}'::uuid[]) <> coalesce(old.assignee_ids,'{}'::uuid[])
       or coalesce(new.due_date::text,'') <> coalesce(old.due_date::text,'')
       or coalesce(new.store_id::text,'') <> coalesce(old.store_id::text,'')
       or new.is_binary <> old.is_binary or new.requires_photo <> old.requires_photo then
      raise exception 'この項目は編集できません';
    end if;
  end if;
  if new.completed_at is not null and old.completed_at is null then
    if new.is_binary and new.judgement is null then
      raise exception '判定（OK・異常あり）を選択してください';
    end if;
    if new.requires_photo and not exists (select 1 from hq_task_photos p where p.step_id = new.id) then
      raise exception '写真の添付が必要です';
    end if;
    if new.completed_by is null then new.completed_by := auth.uid(); end if;
  end if;
  if new.completed_at is null then
    new.completed_by := null;
  end if;
  new.updated_at := now();
  return new;
end;
$$
;

alter table public.hq_slack_task_log add column if not exists card_channel text, add column if not exists parent_ts text, add column if not exists parent_notification_id uuid, add column if not exists card_notification_id uuid;

create or replace function public.hq_slack_task_card_set(p_task uuid, p_channel text, p_ts text, p_parent uuid, p_card uuid) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  update hq_slack_task_log set card_channel = p_channel, parent_ts = p_ts, parent_notification_id = p_parent, card_notification_id = p_card where task_id = p_task;
end $$;

create or replace function public.hq_slack_task_get(p_task uuid) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_t hq_tasks%rowtype; v_l hq_slack_task_log%rowtype; v_a uuid[]; v_slack jsonb; v_steps jsonb;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  select * into v_l from hq_slack_task_log where task_id = p_task;
  select * into v_t from hq_tasks where id = p_task and deleted_at is null;
  if v_l.id is null or v_t.id is null then return jsonb_build_object('ok', false, 'message', 'このタスクは Slack から編集できません'); end if;
  select coalesce(s.assignee_ids, array[s.assignee_id]) into v_a from hq_task_steps s where s.task_id = p_task order by (s.completed_at is not null), s.sort_order limit 1;
  select coalesce(jsonb_agg(us.slack_user_id), '[]'::jsonb) into v_slack from user_slack us where us.user_id = any(coalesce(v_a, array[]::uuid[]));
  select coalesce(jsonb_agg(jsonb_build_object('title', s.title, 'done', s.completed_at is not null) order by s.sort_order), '[]'::jsonb) into v_steps from hq_task_steps s where s.task_id = p_task;
  return jsonb_build_object('ok', true, 'status', v_t.status, 'title', v_t.title, 'corp', v_t.corp, 'due', v_t.due_date, 'due_time', v_t.due_time, 'memo', v_t.description, 'notes', v_t.notes,
    'urgent', v_t.is_urgent, 'assignee_slack_ids', v_slack, 'steps', v_steps, 'creator_id', v_l.created_by, 'card_channel', v_l.card_channel, 'parent_ts', v_l.parent_ts,
    'parent_notification_id', v_l.parent_notification_id, 'card_notification_id', v_l.card_notification_id);
end $$;

create or replace function public.hq_slack_task_update(p_slack_user_id text, p_task uuid, p_title text, p_corp text, p_assignee_ids uuid[], p_due date, p_due_time time, p_memo text, p_notes text,
                                                       p_urgent boolean, p_add_steps text[] default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_u users%rowtype; v_l hq_slack_task_log%rowtype; v_t hq_tasks%rowtype; v_title text := btrim(coalesce(p_title, '')); v_old uuid[]; v_new uuid[]; v_added uuid[]; v_n integer; v_max integer; v_i integer;
  v_lines text[]; v_today date := (now() at time zone 'Asia/Tokyo')::date; v_changes text[] := array[]::text[];
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  select u.* into v_u from user_slack s join users u on u.id = s.user_id where s.slack_user_id = p_slack_user_id and u.is_active;
  if v_u.id is null then return jsonb_build_object('ok', false, 'message', 'あなたの Slack は管理システムに紐づいていません'); end if;
  select * into v_l from hq_slack_task_log where task_id = p_task;
  select * into v_t from hq_tasks where id = p_task and deleted_at is null for update;
  if v_l.id is null or v_t.id is null then return jsonb_build_object('ok', false, 'message', 'このタスクは Slack から編集できません'); end if;
  if not (v_u.id = v_l.created_by or v_u.is_master or v_u.role in ('CEO', 'HQ')) then return jsonb_build_object('ok', false, 'message', '直せるのは、作った人と本部・社長だけです'); end if;
  if v_t.status = 'done' then return jsonb_build_object('ok', false, 'message', '完了したタスクは直せません'); end if;
  if v_title = '' or char_length(v_title) > 120 then return jsonb_build_object('ok', false, 'reason', 'title', 'message', 'やることは 1〜120 文字で入れてください'); end if;
  if p_corp is null or p_corp not in ('トーホー', 'N-Style', 'SK', 'LiveGate') then return jsonb_build_object('ok', false, 'reason', 'corp', 'message', '法人を選んでください'); end if;
  if p_due is null or (p_due < v_today and p_due is distinct from v_t.due_date) then return jsonb_build_object('ok', false, 'reason', 'due', 'message', '期限は今日以降の日付を選んでください'); end if;
  v_new := coalesce(p_assignee_ids, array[]::uuid[]);
  select count(*) into v_n from users u where u.id = any(v_new) and u.is_active;
  if coalesce(array_length(v_new, 1), 0) = 0 or v_n <> array_length(v_new, 1) then return jsonb_build_object('ok', false, 'reason', 'assignee', 'message', '担当者を選んでください'); end if;
  select coalesce(array_agg(btrim(x) order by ord), array[]::text[]) into v_lines from unnest(coalesce(p_add_steps, array[]::text[])) with ordinality a(x, ord) where btrim(x) <> '';
  select count(*) into v_n from hq_task_steps where task_id = p_task;
  if v_n + coalesce(array_length(v_lines, 1), 0) > 10 then return jsonb_build_object('ok', false, 'reason', 'steps', 'message', '工程は全部で 10 個までです'); end if;
  -- 変更の要約（Slack の記録用・金額や個人情報は含まない）
  if v_title is distinct from v_t.title then v_changes := array_append(v_changes, 'やること'::text); end if;
  if p_corp is distinct from v_t.corp then v_changes := array_append(v_changes, '法人'::text); end if;
  if p_due is distinct from v_t.due_date or p_due_time is distinct from v_t.due_time then v_changes := array_append(v_changes, '期限'::text); end if;
  if coalesce(btrim(p_memo), '') is distinct from coalesce(v_t.description, '') then v_changes := array_append(v_changes, '詳細'::text); end if;
  if coalesce(btrim(p_notes), '') is distinct from coalesce(v_t.notes, '') then v_changes := array_append(v_changes, '注意事項'::text); end if;
  if coalesce(p_urgent, false) is distinct from v_t.is_urgent then v_changes := array_append(v_changes, '最重要'::text); end if;
  select coalesce(s.assignee_ids, array[s.assignee_id]) into v_old from hq_task_steps s where s.task_id = p_task and s.completed_at is null order by s.sort_order limit 1;
  if (select array_agg(x order by x) from unnest(coalesce(v_old, array[]::uuid[])) x) is distinct from (select array_agg(x order by x) from unnest(v_new) x) then v_changes := array_append(v_changes, '担当者'::text); end if;
  if coalesce(array_length(v_lines, 1), 0) > 0 then v_changes := array_append(v_changes, '工程の追加'::text); end if;
  select coalesce(array_agg(x), array[]::uuid[]) into v_added from unnest(v_new) x where not (x = any(coalesce(v_old, array[]::uuid[])));

  update hq_tasks set title = v_title, corp = p_corp, description = nullif(btrim(coalesce(p_memo, '')), ''), notes = coalesce(left(btrim(coalesce(p_notes, '')), 1000), ''),
         due_date = p_due, due_time = p_due_time, is_urgent = coalesce(p_urgent, false),
         urgent_marked_by = case when coalesce(p_urgent, false) and not v_t.is_urgent then v_u.id when not coalesce(p_urgent, false) then null else v_t.urgent_marked_by end,
         urgent_marked_at = case when coalesce(p_urgent, false) and not v_t.is_urgent then now() when not coalesce(p_urgent, false) then null else v_t.urgent_marked_at end, updated_at = now()
   where id = p_task;
  perform set_config('hq.slack_edit', '1', true);
  update hq_task_steps set assignee_ids = v_new, due_date = p_due, due_time = p_due_time where task_id = p_task and completed_at is null;
  perform set_config('hq.slack_edit', '', true);
  select coalesce(max(sort_order), 0) into v_max from hq_task_steps where task_id = p_task;
  for v_i in 1..coalesce(array_length(v_lines, 1), 0) loop
    insert into hq_task_steps(task_id, title, assignee_ids, due_date, due_time, sort_order, kind) values (p_task, left(v_lines[v_i], 80), v_new, p_due, p_due_time, v_max + v_i * 10, 'step');
  end loop;
  insert into hq_task_activity(task_id, actor_id, kind, detail) values (p_task, v_u.id, 'comment', 'Slack から編集（' || coalesce(array_to_string(v_changes, '・'), '変更なし') || '）');
  return jsonb_build_object('ok', true, 'changes', to_jsonb(v_changes), 'editor_name', v_u.name, 'new_assignees', to_jsonb(v_added), 'title', v_title, 'due', p_due, 'due_time', p_due_time,
    'step_id', (select s.id from hq_task_steps s where s.task_id = p_task and s.completed_at is null order by s.sort_order limit 1), 'creator_id', v_l.created_by);
end $$;
revoke all on function public.hq_slack_task_card_set(uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke all on function public.hq_slack_task_get(uuid) from public, anon, authenticated;
revoke all on function public.hq_slack_task_update(text, uuid, text, text, uuid[], date, time, text, text, boolean, text[]) from public, anon, authenticated;
grant execute on function public.hq_slack_task_card_set(uuid, text, text, uuid, uuid) to service_role;
grant execute on function public.hq_slack_task_get(uuid) to service_role;
grant execute on function public.hq_slack_task_update(text, uuid, text, text, uuid[], date, time, text, text, boolean, text[]) to service_role;
