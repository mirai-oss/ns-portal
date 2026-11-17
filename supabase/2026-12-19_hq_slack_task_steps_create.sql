-- Slack の作成フォームで、工程ごとに「工程名・担当者・期限（日付＋時刻）」を入れられるようにする（2026-11-17・社長依頼）
--   ・hq_slack_task_create_steps: 工程の配列を受け取って、タスク＋工程をまとめて作る（1 つでも不正なら何も作らない・同じ送信の二重登録なし・タスク全体の期限は工程の最も遅い期限）。
--   ・hq_slack_reminder_candidates: Slack で付けたタスクは、未完了の工程すべてを通知の対象にする（工程ごとに担当者・期限が違うため。ほかのタスクは今までどおり「いまの工程」だけ）。
--   ・hq_slack_step_complete: Slack で付けたタスクは、工程を順番に関係なく、その担当者が完了にできる。
-- 戻し方: 2026-12-13_hq_slack_task.sql の hq_slack_reminder_candidates / hq_slack_step_complete を流し直し、drop function hq_slack_task_create_steps(...)

create or replace function public.hq_slack_task_create_steps(p_slack_user_id text, p_title text, p_corp text, p_memo text, p_notes text, p_urgent boolean, p_photo boolean, p_steps jsonb, p_dedupe text, p_source jsonb default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_u users%rowtype; v_task uuid; v_prev uuid; v_title text := btrim(coalesce(p_title, '')); v_n integer; v_i integer; v_e jsonb; v_ids uuid[]; v_due date; v_time time; v_stitle text; v_sid uuid; v_maxdue date; v_maxtime time;
  v_today date := (now() at time zone 'Asia/Tokyo')::date; v_out jsonb := '[]'::jsonb; v_first uuid;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  if not public.hq_slack_flag('create_enabled') then return jsonb_build_object('ok', false, 'reason', 'switch_off', 'message', 'Slack からのタスク作成は、まだ有効になっていません'); end if;
  select u.* into v_u from user_slack s join users u on u.id = s.user_id where s.slack_user_id = p_slack_user_id and u.is_active;
  if v_u.id is null then return jsonb_build_object('ok', false, 'reason', 'not_linked', 'message', 'あなたの Slack は管理システムに紐づいていません'); end if;
  if not (v_u.is_master or v_u.role in ('CEO', 'HQ', 'TENCHO')) then return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', 'タスクを作れるのは、本部・社長・店長だけです'); end if;
  if p_dedupe is null or btrim(p_dedupe) = '' then raise exception '送信の識別が必要です'; end if;
  select l.task_id into v_prev from hq_slack_task_log l where l.dedupe_key = p_dedupe;
  if v_prev is not null then return jsonb_build_object('ok', true, 'task_id', v_prev, 'duplicate', true); end if;
  if v_title = '' or char_length(v_title) > 120 then return jsonb_build_object('ok', false, 'reason', 'title', 'message', 'やることは 1〜120 文字で入れてください'); end if;
  if p_corp is null or p_corp not in ('トーホー', 'N-Style', 'SK', 'LiveGate') then return jsonb_build_object('ok', false, 'reason', 'corp', 'message', '法人を選んでください'); end if;
  v_n := coalesce(jsonb_array_length(p_steps), 0);
  if v_n < 1 or v_n > 10 then return jsonb_build_object('ok', false, 'reason', 'steps', 'message', '工程は 1〜10 個にしてください'); end if;
  -- 先に全部の工程を確かめる（1 つでも不正なら何も作らない）
  for v_i in 0..v_n - 1 loop
    v_e := p_steps -> v_i;
    select coalesce(array_agg(x::uuid), array[]::uuid[]) into v_ids from jsonb_array_elements_text(coalesce(v_e -> 'assignee_ids', '[]'::jsonb)) x;
    select count(*) into v_n from users u where u.id = any(v_ids) and u.is_active;
    if coalesce(array_length(v_ids, 1), 0) = 0 or v_n <> array_length(v_ids, 1) then return jsonb_build_object('ok', false, 'reason', 'assignee', 'message', '工程 ' || (v_i + 1) || ' の担当者を選んでください'); end if;
    v_due := nullif(v_e ->> 'due', '')::date;
    if v_due is null or v_due < v_today then return jsonb_build_object('ok', false, 'reason', 'due', 'message', '工程 ' || (v_i + 1) || ' の期限は今日以降の日付を選んでください'); end if;
    v_n := jsonb_array_length(p_steps);
  end loop;
  select max((e ->> 'due')::date) into v_maxdue from jsonb_array_elements(p_steps) e;
  select max(nullif(e ->> 'due_time', '')::time) into v_maxtime from jsonb_array_elements(p_steps) e where (e ->> 'due')::date = v_maxdue;
  insert into hq_tasks(title, corp, freq, target_date, due_date, due_time, notes, description, visibility, created_by, is_urgent, urgent_marked_by, urgent_marked_at)
  values (v_title, p_corp, 'once', v_today, v_maxdue, v_maxtime, coalesce(left(btrim(coalesce(p_notes, '')), 1000), ''), nullif(btrim(coalesce(p_memo, '')), ''), 'all', v_u.id, coalesce(p_urgent, false),
          case when coalesce(p_urgent, false) then v_u.id end, case when coalesce(p_urgent, false) then now() end)
  returning id into v_task;
  for v_i in 0..v_n - 1 loop
    v_e := p_steps -> v_i;
    select coalesce(array_agg(x::uuid), array[]::uuid[]) into v_ids from jsonb_array_elements_text(v_e -> 'assignee_ids') x;
    v_stitle := left(btrim(coalesce(v_e ->> 'title', '')), 80); if v_stitle = '' then v_stitle := '対応する'; end if;
    insert into hq_task_steps(task_id, title, assignee_ids, due_date, due_time, sort_order, kind, requires_photo)
    values (v_task, v_stitle, v_ids, (v_e ->> 'due')::date, nullif(v_e ->> 'due_time', '')::time, (v_i + 1) * 10, 'step', coalesce(p_photo, false)) returning id into v_sid;
    if v_i = 0 then v_first := v_sid; end if;
    v_out := v_out || jsonb_build_object('step_id', v_sid, 'title', v_stitle, 'assignee_ids', to_jsonb(v_ids), 'due', v_e ->> 'due', 'due_time', nullif(v_e ->> 'due_time', ''));
  end loop;
  insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, v_u.id, 'create', 'Slack のフォームから作成（工程 ' || v_n || '）');
  insert into hq_slack_task_log(dedupe_key, task_id, created_by, source) values (p_dedupe, v_task, v_u.id, p_source);
  return jsonb_build_object('ok', true, 'task_id', v_task, 'step_id', v_first, 'creator_id', v_u.id, 'creator_name', v_u.name, 'steps', v_out, 'duplicate', false, 'due', v_maxdue, 'due_time', v_maxtime);
end $$;
revoke all on function public.hq_slack_task_create_steps(text, text, text, text, text, boolean, boolean, jsonb, text, jsonb) from public, anon, authenticated;
grant execute on function public.hq_slack_task_create_steps(text, text, text, text, text, boolean, boolean, jsonb, text, jsonb) to service_role;

CREATE OR REPLACE FUNCTION public.hq_slack_reminder_candidates()
 RETURNS TABLE(recipient_id uuid, slack_user_id text, task_id uuid, step_id uuid, task_title text, step_title text, due_date date, due_time time without time zone, kind text, days_over integer, creator_id uuid, can_complete boolean, url text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date; v_hour integer := extract(hour from (now() at time zone 'Asia/Tokyo'))::integer;
        v_esc integer := coalesce((select (s.value ->> 'escalate_days')::integer from app_settings s where s.key = 'hq_task_slack'), 3);
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  return query
  with cur as (
    select t.id as tid, t.title as ttitle, t.created_by, t.template_id, s.id as sid, s.title as stitle, coalesce(s.due_date, t.due_date) as due, coalesce(s.due_time, t.due_time) as dtime,
           coalesce(s.assignee_ids, case when s.assignee_id is not null then array[s.assignee_id] end, array[t.created_by]) as rcpt,
           (s.kind = 'step' and not s.is_binary and not s.requires_photo and not exists (select 1 from hq_step_checklist_items i where i.step_id = s.id)) as plain,
           a.before3 as a3, a.before1 as a1, a.due as ad, a.overdue_daily as ao,
           tp.alert_before3 as t3, tp.alert_before1 as t1, tp.alert_due as td, tp.alert_overdue_daily as tod
      from hq_tasks t
      join lateral (select s2.* from hq_task_steps s2 where s2.task_id = t.id and s2.completed_at is null
                     and (s2.id = (select s3.id from hq_task_steps s3 where s3.task_id = t.id and s3.completed_at is null order by s3.sort_order limit 1)
                          or exists (select 1 from hq_slack_task_log l where l.task_id = t.id))   -- 2026-11-17: Slack で付けたタスクは、未完了の工程すべてを対象（工程ごとに担当者・期限が違うため）
                     order by s2.sort_order) s on true
      left join hq_task_alerts a on a.task_id = t.id
      left join hq_task_templates tp on tp.id = t.template_id
     where t.status <> 'done' and t.deleted_at is null and coalesce(s.due_date, t.due_date) is not null
  ), kinds as (
    select c.*, (c.due - v_today) as d,
           case when c.due < v_today and coalesce(c.ao, c.tod, true) then 'overdue'
                when c.due = v_today and coalesce(c.ad, c.td, true) then 'today'
                when c.due = v_today + 1 and coalesce(c.a1, c.t1, true) then 'before1'
                when c.due = v_today + 3 and coalesce(c.a3, c.t3, true) then 'before3' end as k
      from cur c
  ), expanded as (
    select k.tid, k.ttitle, k.created_by, k.sid, k.stitle, k.due, k.dtime, k.plain, k.k as kind, (v_today - k.due) as over, r as rid, false as esc from kinds k, unnest(k.rcpt) r where k.k is not null
    union all
    select k.tid, k.ttitle, k.created_by, k.sid, k.stitle, k.due, k.dtime, k.plain, k.k || '_pm', (v_today - k.due), r, false from kinds k, unnest(k.rcpt) r
     where k.k in ('today', 'overdue') and v_hour >= 15
       and not exists (select 1 from hq_slack_reminder_log l where l.step_id = k.sid and l.recipient_id = r and l.kind = 'ack' and l.sent_on = v_today)
    union all
    select k.tid, k.ttitle, k.created_by, k.sid, k.stitle, k.due, k.dtime, k.plain, 'escalate', (v_today - k.due), k.created_by, true from kinds k
     where k.k = 'overdue' and (v_today - k.due) >= v_esc and k.created_by is not null and not (k.created_by = any(k.rcpt))
  )
  select e.rid, us.slack_user_id, e.tid, e.sid, e.ttitle, e.stitle, e.due, e.dtime, e.kind, greatest(e.over, 0), e.created_by, e.plain,
         'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || e.tid
    from expanded e
    join users u on u.id = e.rid and u.is_active
    join user_slack us on us.user_id = e.rid
   where not exists (select 1 from hq_slack_reminder_log l where l.step_id = e.sid and l.recipient_id = e.rid and l.kind = e.kind and l.sent_on = v_today)
   order by e.due, e.tid;
end $$
;

CREATE OR REPLACE FUNCTION public.hq_slack_step_complete(p_slack_user_id text, p_step uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare v_u users%rowtype; v_s hq_task_steps%rowtype; v_first uuid; v_status text;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  select u.* into v_u from user_slack s join users u on u.id = s.user_id where s.slack_user_id = p_slack_user_id and u.is_active;
  if v_u.id is null then return jsonb_build_object('ok', false, 'message', 'Slack が管理システムに紐づいていません'); end if;
  select * into v_s from hq_task_steps where id = p_step for update;
  if v_s.id is null then return jsonb_build_object('ok', false, 'message', '工程が見つかりません'); end if;
  if v_s.completed_at is not null then return jsonb_build_object('ok', true, 'already', true, 'message', 'すでに完了しています'); end if;
  if not (v_u.id = any(coalesce(v_s.assignee_ids, array[v_s.assignee_id])) or v_u.is_master or v_u.role in ('CEO', 'HQ')) then
    return jsonb_build_object('ok', false, 'message', 'この工程の担当者だけが完了にできます');
  end if;
  select s2.id into v_first from hq_task_steps s2 where s2.task_id = v_s.task_id and s2.completed_at is null order by s2.sort_order limit 1;
  if v_first is distinct from v_s.id and not exists (select 1 from hq_slack_task_log l where l.task_id = v_s.task_id) then return jsonb_build_object('ok', false, 'message', '前の工程が終わっていません。管理システムで確認してください'); end if;   -- Slack で付けたタスクは順番なし
  if v_s.kind <> 'step' or v_s.is_binary or v_s.requires_photo or exists (select 1 from hq_step_checklist_items i where i.step_id = v_s.id) then
    return jsonb_build_object('ok', false, 'need_screen', true, 'message', '写真・判定・名簿のある工程は、管理システムの画面で完了にしてください');
  end if;
  update hq_task_steps set completed_at = now(), completed_by = v_u.id where id = v_s.id;
  insert into hq_task_activity(task_id, step_id, actor_id, kind, detail) values (v_s.task_id, v_s.id, v_u.id, 'step_complete', 'Slack の DM から完了');
  select t.status into v_status from hq_tasks t where t.id = v_s.task_id;
  return jsonb_build_object('ok', true, 'task_status', v_status, 'task_id', v_s.task_id);
end $$
;
