-- 本部タスクの Slack フォームの拡張（2026-11-17）: 期限の時刻・注意事項・工程（1 行 1 工程）・写真必須。
--   hq_slack_task_create を、引数を足した版に置き換える（古い引数の版は消す。呼び先は slack-interact だけ）。hq_slack_reminder_candidates に期限の時刻（due_time）を足す。
-- 戻し方: 2026-12-13_hq_slack_task.sql の同名の関数を流し直す。
drop function if exists public.hq_slack_task_create(text, text, text, uuid[], date, text, boolean, text, jsonb);
drop function if exists public.hq_slack_reminder_candidates();
create or replace function public.hq_slack_task_create(p_slack_user_id text, p_title text, p_corp text, p_assignee_ids uuid[], p_due date, p_memo text,
                                                       p_urgent boolean, p_dedupe text, p_source jsonb default null,
                                                       p_due_time time default null, p_notes text default null, p_steps text[] default null, p_photo boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_u users%rowtype; v_task uuid; v_step uuid; v_ids uuid[]; v_title text := btrim(coalesce(p_title, '')); v_prev uuid; v_n integer;
  v_today date := (now() at time zone 'Asia/Tokyo')::date; v_lines text[]; v_i integer; v_s uuid;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  if not public.hq_slack_flag('create_enabled') then return jsonb_build_object('ok', false, 'reason', 'switch_off', 'message', 'Slack からのタスク作成は、まだ有効になっていません'); end if;
  select u.* into v_u from user_slack s join users u on u.id = s.user_id where s.slack_user_id = p_slack_user_id and u.is_active;
  if v_u.id is null then return jsonb_build_object('ok', false, 'reason', 'not_linked', 'message', 'あなたの Slack は管理システムに紐づいていません'); end if;
  if not (v_u.is_master or v_u.role in ('CEO', 'HQ', 'TENCHO')) then
    return jsonb_build_object('ok', false, 'reason', 'forbidden', 'message', 'タスクを作れるのは、本部・社長・店長だけです');
  end if;
  if p_dedupe is null or btrim(p_dedupe) = '' then raise exception '送信の識別が必要です'; end if;
  select l.task_id into v_prev from hq_slack_task_log l where l.dedupe_key = p_dedupe;
  if v_prev is not null then return jsonb_build_object('ok', true, 'task_id', v_prev, 'duplicate', true); end if;
  if v_title = '' or char_length(v_title) > 120 then return jsonb_build_object('ok', false, 'reason', 'title', 'message', 'タスク名は 1〜120 文字で入れてください'); end if;
  if p_corp is null or p_corp not in ('トーホー', 'N-Style', 'SK', 'LiveGate') then return jsonb_build_object('ok', false, 'reason', 'corp', 'message', '法人を選んでください'); end if;
  if p_due is null or p_due < v_today then return jsonb_build_object('ok', false, 'reason', 'due', 'message', '期限は今日以降の日付を選んでください'); end if;
  v_ids := coalesce(p_assignee_ids, array[]::uuid[]);
  select count(*) into v_n from users u where u.id = any(v_ids) and u.is_active;
  if coalesce(array_length(v_ids, 1), 0) = 0 or v_n <> array_length(v_ids, 1) then
    return jsonb_build_object('ok', false, 'reason', 'assignee', 'message', '担当者を選んでください（Slack と紐づいていない人は選べません）');
  end if;
  -- 工程: 1 行 1 工程（空行は除く・最大 10・各 80 文字まで）。無ければ「対応する」1 つ
  select coalesce(array_agg(left(btrim(x), 80) order by ord), array[]::text[]) into v_lines from unnest(coalesce(p_steps, array[]::text[])) with ordinality as a(x, ord) where btrim(x) <> '';
  if coalesce(array_length(v_lines, 1), 0) > 10 then return jsonb_build_object('ok', false, 'reason', 'steps', 'message', '工程は 10 個までです'); end if;
  if coalesce(array_length(v_lines, 1), 0) = 0 then v_lines := array['対応する']; end if;
  insert into hq_tasks(title, corp, freq, target_date, due_date, due_time, notes, description, visibility, created_by, is_urgent, urgent_marked_by, urgent_marked_at)
  values (v_title, p_corp, 'once', v_today, p_due, p_due_time, coalesce(left(btrim(coalesce(p_notes, '')), 1000), ''), nullif(btrim(coalesce(p_memo, '')), ''), 'all', v_u.id, coalesce(p_urgent, false),
          case when coalesce(p_urgent, false) then v_u.id end, case when coalesce(p_urgent, false) then now() end)
  returning id into v_task;
  for v_i in 1..array_length(v_lines, 1) loop
    insert into hq_task_steps(task_id, title, assignee_ids, due_date, due_time, sort_order, kind, requires_photo)
    values (v_task, v_lines[v_i], v_ids, p_due, p_due_time, v_i * 10, 'step', coalesce(p_photo, false)) returning id into v_s;
    if v_i = 1 then v_step := v_s; end if;
  end loop;
  insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, v_u.id, 'create', 'Slack のフォームから作成（工程 ' || array_length(v_lines, 1) || '）');
  insert into hq_slack_task_log(dedupe_key, task_id, created_by, source) values (p_dedupe, v_task, v_u.id, p_source);
  return jsonb_build_object('ok', true, 'task_id', v_task, 'step_id', v_step, 'creator_id', v_u.id, 'creator_name', v_u.name, 'steps', array_length(v_lines, 1), 'duplicate', false);
end $$;
revoke all on function public.hq_slack_task_create(text, text, text, uuid[], date, text, boolean, text, jsonb, time, text, text[], boolean) from public, anon, authenticated;
grant execute on function public.hq_slack_task_create(text, text, text, uuid[], date, text, boolean, text, jsonb, time, text, text[], boolean) to service_role;


create or replace function public.hq_slack_reminder_candidates()
returns table(recipient_id uuid, slack_user_id text, task_id uuid, step_id uuid, task_title text, step_title text, due_date date, due_time time, kind text, days_over integer,
              creator_id uuid, can_complete boolean, url text)
language plpgsql security definer set search_path to 'public' as $$
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
      join lateral (select s2.* from hq_task_steps s2 where s2.task_id = t.id and s2.completed_at is null order by s2.sort_order limit 1) s on true
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
end $$;
revoke all on function public.hq_slack_reminder_candidates() from public, anon, authenticated;
grant execute on function public.hq_slack_reminder_candidates() to service_role;


