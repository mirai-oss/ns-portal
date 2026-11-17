-- Slack から工程ごとに担当者・期限などを直す（2026-11-17・社長の指摘: 工程の担当者と期限が全工程で共通だとやりにくい／編集で工程が追加されてしまう）
--   ・hq_slack_task_update: 担当者・期限・追加工程を「渡されたときだけ」直す（null は変えない）。フォームは、やること・法人・詳細・注意事項・最重要だけを送る。
--   ・hq_slack_steps_get: 工程の一覧（名前・担当者・期限・完了・写真・メモ）。service_role 専用。
--   ・hq_slack_step_update: 1 つの工程を直す／削除する／新しく追加する（p_step が null なら追加）。直せる人＝作成者・本部・社長・マスター。完了した工程は直せない・消せない。工程は 1 つ以上残す・10 個まで。
--     タスク全体の期限は、工程の期限のうち最も遅いものに合わせる。
-- 戻し方: 2026-12-17_hq_slack_task_edit.sql の hq_slack_task_update を流し直し、drop function hq_slack_steps_get(uuid), hq_slack_step_update(...)

create or replace function public.hq_slack_task_update(p_slack_user_id text, p_task uuid, p_title text, p_corp text, p_assignee_ids uuid[], p_due date, p_due_time time, p_memo text, p_notes text,
                                                       p_urgent boolean, p_add_steps text[] default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_u users%rowtype; v_l hq_slack_task_log%rowtype; v_t hq_tasks%rowtype; v_title text := btrim(coalesce(p_title, '')); v_old uuid[]; v_new uuid[]; v_added uuid[]; v_n integer; v_max integer; v_i integer;
  v_lines text[]; v_today date := (now() at time zone 'Asia/Tokyo')::date; v_changes text[] := array[]::text[]; v_due date; v_time time;
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
  v_due := coalesce(p_due, v_t.due_date); v_time := case when p_due is null then v_t.due_time else p_due_time end;
  if p_due is not null and p_due < v_today and p_due is distinct from v_t.due_date then return jsonb_build_object('ok', false, 'reason', 'due', 'message', '期限は今日以降の日付を選んでください'); end if;
  if p_assignee_ids is not null then
    v_new := p_assignee_ids;
    select count(*) into v_n from users u where u.id = any(v_new) and u.is_active;
    if coalesce(array_length(v_new, 1), 0) = 0 or v_n <> array_length(v_new, 1) then return jsonb_build_object('ok', false, 'reason', 'assignee', 'message', '担当者を選んでください'); end if;
  end if;
  select coalesce(array_agg(btrim(x) order by ord), array[]::text[]) into v_lines from unnest(coalesce(p_add_steps, array[]::text[])) with ordinality a(x, ord) where btrim(x) <> '';
  select count(*) into v_n from hq_task_steps where task_id = p_task;
  if v_n + coalesce(array_length(v_lines, 1), 0) > 10 then return jsonb_build_object('ok', false, 'reason', 'steps', 'message', '工程は全部で 10 個までです'); end if;
  if v_title is distinct from v_t.title then v_changes := array_append(v_changes, 'やること'::text); end if;
  if p_corp is distinct from v_t.corp then v_changes := array_append(v_changes, '法人'::text); end if;
  if p_due is not null and (p_due is distinct from v_t.due_date or p_due_time is distinct from v_t.due_time) then v_changes := array_append(v_changes, '期限'::text); end if;
  if coalesce(btrim(p_memo), '') is distinct from coalesce(v_t.description, '') then v_changes := array_append(v_changes, '詳細'::text); end if;
  if coalesce(btrim(p_notes), '') is distinct from coalesce(v_t.notes, '') then v_changes := array_append(v_changes, '注意事項'::text); end if;
  if coalesce(p_urgent, false) is distinct from v_t.is_urgent then v_changes := array_append(v_changes, '最重要'::text); end if;
  select coalesce(s.assignee_ids, array[s.assignee_id]) into v_old from hq_task_steps s where s.task_id = p_task and s.completed_at is null order by s.sort_order limit 1;
  if p_assignee_ids is not null and (select array_agg(x order by x) from unnest(coalesce(v_old, array[]::uuid[])) x) is distinct from (select array_agg(x order by x) from unnest(v_new) x) then v_changes := array_append(v_changes, '担当者'::text); end if;
  if coalesce(array_length(v_lines, 1), 0) > 0 then v_changes := array_append(v_changes, '工程の追加'::text); end if;
  select coalesce(array_agg(x), array[]::uuid[]) into v_added from unnest(coalesce(v_new, array[]::uuid[])) x where not (x = any(coalesce(v_old, array[]::uuid[])));
  update hq_tasks set title = v_title, corp = p_corp, description = nullif(btrim(coalesce(p_memo, '')), ''), notes = coalesce(left(btrim(coalesce(p_notes, '')), 1000), ''),
         due_date = v_due, due_time = v_time, is_urgent = coalesce(p_urgent, false),
         urgent_marked_by = case when coalesce(p_urgent, false) and not v_t.is_urgent then v_u.id when not coalesce(p_urgent, false) then null else v_t.urgent_marked_by end,
         urgent_marked_at = case when coalesce(p_urgent, false) and not v_t.is_urgent then now() when not coalesce(p_urgent, false) then null else v_t.urgent_marked_at end, updated_at = now()
   where id = p_task;
  perform set_config('hq.slack_edit', '1', true);
  if p_assignee_ids is not null then update hq_task_steps set assignee_ids = v_new where task_id = p_task and completed_at is null; end if;
  if p_due is not null then update hq_task_steps set due_date = p_due, due_time = p_due_time where task_id = p_task and completed_at is null; end if;
  perform set_config('hq.slack_edit', '', true);
  select coalesce(max(sort_order), 0) into v_max from hq_task_steps where task_id = p_task;
  for v_i in 1..coalesce(array_length(v_lines, 1), 0) loop
    insert into hq_task_steps(task_id, title, assignee_ids, due_date, due_time, sort_order, kind)
    values (p_task, left(v_lines[v_i], 80), coalesce(v_new, v_old), v_due, v_time, v_max + v_i * 10, 'step');
  end loop;
  insert into hq_task_activity(task_id, actor_id, kind, detail) values (p_task, v_u.id, 'comment', 'Slack から編集（' || coalesce(nullif(array_to_string(v_changes, '・'), ''), '変更なし') || '）');
  return jsonb_build_object('ok', true, 'changes', to_jsonb(v_changes), 'editor_name', v_u.name, 'new_assignees', to_jsonb(v_added), 'title', v_title, 'due', v_due, 'due_time', v_time,
    'step_id', (select s.id from hq_task_steps s where s.task_id = p_task and s.completed_at is null order by s.sort_order limit 1), 'creator_id', v_l.created_by);
end $$;

create or replace function public.hq_slack_steps_get(p_task uuid) returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  if not exists (select 1 from hq_slack_task_log where task_id = p_task) then return jsonb_build_object('ok', false, 'message', 'このタスクは Slack から編集できません'); end if;
  return jsonb_build_object('ok', true, 'status', (select status from hq_tasks where id = p_task), 'title', (select title from hq_tasks where id = p_task),
    'steps', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'due', s.due_date, 'due_time', s.due_time, 'done', s.completed_at is not null, 'photo', s.requires_photo, 'note', s.procedure_note,
        'assignee_names', (select coalesce(jsonb_agg(replace(replace(u.name, ' ', ''), chr(12288), '')), '[]'::jsonb) from users u where u.id = any(coalesce(s.assignee_ids, array[s.assignee_id]))),
        'assignee_slack_ids', (select coalesce(jsonb_agg(us.slack_user_id), '[]'::jsonb) from user_slack us where us.user_id = any(coalesce(s.assignee_ids, array[s.assignee_id])))) order by s.sort_order)
      from hq_task_steps s where s.task_id = p_task), '[]'::jsonb));
end $$;

create or replace function public.hq_slack_step_update(p_slack_user_id text, p_task uuid, p_step uuid, p_title text, p_assignee_ids uuid[], p_due date, p_due_time time, p_photo boolean, p_note text, p_delete boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_u users%rowtype; v_l hq_slack_task_log%rowtype; v_t hq_tasks%rowtype; v_s hq_task_steps%rowtype; v_title text := btrim(coalesce(p_title, '')); v_n integer; v_old uuid[]; v_added uuid[];
  v_today date := (now() at time zone 'Asia/Tokyo')::date; v_changes text[] := array[]::text[]; v_new_step uuid; v_max integer;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  select u.* into v_u from user_slack s join users u on u.id = s.user_id where s.slack_user_id = p_slack_user_id and u.is_active;
  if v_u.id is null then return jsonb_build_object('ok', false, 'message', 'あなたの Slack は管理システムに紐づいていません'); end if;
  select * into v_l from hq_slack_task_log where task_id = p_task;
  select * into v_t from hq_tasks where id = p_task and deleted_at is null for update;
  if v_l.id is null or v_t.id is null then return jsonb_build_object('ok', false, 'message', 'このタスクは Slack から編集できません'); end if;
  if not (v_u.id = v_l.created_by or v_u.is_master or v_u.role in ('CEO', 'HQ')) then return jsonb_build_object('ok', false, 'message', '直せるのは、作った人と本部・社長だけです'); end if;
  if v_t.status = 'done' then return jsonb_build_object('ok', false, 'message', '完了したタスクは直せません'); end if;
  if p_step is not null then
    select * into v_s from hq_task_steps where id = p_step and task_id = p_task for update;
    if v_s.id is null then return jsonb_build_object('ok', false, 'message', '工程が見つかりません'); end if;
    if v_s.completed_at is not null then return jsonb_build_object('ok', false, 'message', '完了した工程は直せません'); end if;
  end if;
  if coalesce(p_delete, false) then
    if p_step is null then return jsonb_build_object('ok', false, 'message', '消す工程を選んでください'); end if;
    select count(*) into v_n from hq_task_steps where task_id = p_task;
    if v_n <= 1 then return jsonb_build_object('ok', false, 'message', '工程は 1 つ以上必要です（最後の 1 つは消せません）'); end if;
    delete from hq_task_steps where id = p_step;
    v_changes := array_append(v_changes, '工程「' || v_s.title || '」を削除'::text);
  else
    if v_title = '' or char_length(v_title) > 80 then return jsonb_build_object('ok', false, 'reason', 'title', 'message', '工程名は 1〜80 文字で入れてください'); end if;
    if p_due is null or (p_due < v_today and (p_step is null or p_due is distinct from v_s.due_date)) then return jsonb_build_object('ok', false, 'reason', 'due', 'message', '期限は今日以降の日付を選んでください'); end if;
    select count(*) into v_n from users u where u.id = any(coalesce(p_assignee_ids, array[]::uuid[])) and u.is_active;
    if coalesce(array_length(p_assignee_ids, 1), 0) = 0 or v_n <> array_length(p_assignee_ids, 1) then return jsonb_build_object('ok', false, 'reason', 'assignee', 'message', '担当者を選んでください'); end if;
    perform set_config('hq.slack_edit', '1', true);
    if p_step is null then
      select count(*) into v_n from hq_task_steps where task_id = p_task;
      if v_n >= 10 then perform set_config('hq.slack_edit', '', true); return jsonb_build_object('ok', false, 'reason', 'steps', 'message', '工程は 10 個までです'); end if;
      select coalesce(max(sort_order), 0) into v_max from hq_task_steps where task_id = p_task;
      insert into hq_task_steps(task_id, title, assignee_ids, due_date, due_time, sort_order, kind, requires_photo, procedure_note)
      values (p_task, v_title, p_assignee_ids, p_due, p_due_time, v_max + 10, 'step', coalesce(p_photo, false), nullif(btrim(coalesce(p_note, '')), '')) returning id into v_new_step;
      v_added := p_assignee_ids; v_changes := array_append(v_changes, '工程「' || v_title || '」を追加'::text);
    else
      v_old := coalesce(v_s.assignee_ids, array[v_s.assignee_id]);
      if v_title is distinct from v_s.title then v_changes := array_append(v_changes, '工程名'::text); end if;
      if (select array_agg(x order by x) from unnest(coalesce(v_old, array[]::uuid[])) x) is distinct from (select array_agg(x order by x) from unnest(p_assignee_ids) x) then v_changes := array_append(v_changes, '担当者'::text); end if;
      if p_due is distinct from v_s.due_date or p_due_time is distinct from v_s.due_time then v_changes := array_append(v_changes, '期限'::text); end if;
      if coalesce(p_photo, false) is distinct from v_s.requires_photo then v_changes := array_append(v_changes, '写真'::text); end if;
      if coalesce(btrim(p_note), '') is distinct from coalesce(v_s.procedure_note, '') then v_changes := array_append(v_changes, 'メモ'::text); end if;
      select coalesce(array_agg(x), array[]::uuid[]) into v_added from unnest(p_assignee_ids) x where not (x = any(coalesce(v_old, array[]::uuid[])));
      update hq_task_steps set title = v_title, assignee_ids = p_assignee_ids, due_date = p_due, due_time = p_due_time, requires_photo = coalesce(p_photo, false), procedure_note = nullif(btrim(coalesce(p_note, '')), '')
       where id = p_step;
    end if;
    perform set_config('hq.slack_edit', '', true);
  end if;
  -- タスク全体の期限は、工程の期限のうち最も遅いものに合わせる
  update hq_tasks t set due_date = x.d, due_time = x.tm, updated_at = now()
    from (select s.due_date d, s.due_time tm from hq_task_steps s where s.task_id = p_task and s.due_date is not null order by s.due_date desc, coalesce(s.due_time, '23:59'::time) desc limit 1) x
   where t.id = p_task and (t.due_date is distinct from x.d or t.due_time is distinct from x.tm);
  insert into hq_task_activity(task_id, actor_id, kind, detail) values (p_task, v_u.id, 'comment', 'Slack から工程を編集（' || coalesce(nullif(array_to_string(v_changes, ' '), ''), '変更なし') || '）');
  return jsonb_build_object('ok', true, 'changes', to_jsonb(v_changes), 'editor_name', v_u.name, 'new_assignees', to_jsonb(coalesce(v_added, array[]::uuid[])), 'step_id', coalesce(v_new_step, p_step), 'step_title', case when coalesce(p_delete, false) then v_s.title else v_title end, 'title', v_t.title);
end $$;
revoke all on function public.hq_slack_steps_get(uuid) from public, anon, authenticated;
revoke all on function public.hq_slack_step_update(text, uuid, uuid, text, uuid[], date, time, boolean, text, boolean) from public, anon, authenticated;
grant execute on function public.hq_slack_steps_get(uuid) to service_role;
grant execute on function public.hq_slack_step_update(text, uuid, uuid, text, uuid[], date, time, boolean, text, boolean) to service_role;
