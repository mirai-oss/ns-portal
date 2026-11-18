-- 2026-11-19 担当B（社長の承認）— 本部タスク（Slack）
--  ① 完了の取り消し: 間違えて完了にした工程を、Slack のカードから取り消せる（新しい関数 hq_slack_step_reopen）。管理システムの「完了を取り消し」と同じ戻し方（完了日時・判定・メモを空に）。
--     取り消せる人: 完了した本人・その工程の担当者・タスクの作成者・マスター/CEO/HQ。
--  ② 「いまの工程」を、期限が早い順に（管理システムの画面と同じ並び）: 既存の関数 2 つの「並び順の 1 行」だけを置き換える
--     （hq_slack_reminder_candidates＝毎朝などの定期DM／hq_slack_step_complete＝Slack の［完了］）。中身が想定と違えば何も変えずに止まる。
--  ③ 次の担当者への通知（新しい関数 hq_slack_next_candidates）: 前の工程が止まっているとき、次の工程の担当者に知らせる候補を返す。
--       next_today=前の工程が期限の当日で未完了（1 回）／next_over=前の工程が期限超過（超過 1 日目と、その後 3 日ごと）／next_ready=前の工程が完了した（あなたの番です・1 回）
--     次の 1 人（直前の工程の次）だけ・同じ人が両方の担当なら出さない。送るのは EF hq-task-reminders（設定 hq_task_slack.next_notice_enabled が true のときだけ。最初は false）。
-- 【戻し方】drop function public.hq_slack_step_reopen(text, uuid); drop function public.hq_slack_next_candidates(); ②は 2026-12-13/12-15 の関数定義を再実行
do $do$
declare r record; v_def text; v_new text; v_old text; v_rep text;
begin
  for r in select p.oid, p.proname from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('hq_slack_reminder_candidates', 'hq_slack_step_complete') loop
    -- 置き換える 1 行（関数ごと）。hq_slack_reminder_candidates の「いまの工程」＝ s3 の行、hq_slack_step_complete の「先頭の未完了」＝ s2 の行
    if r.proname = 'hq_slack_reminder_candidates' then
      v_old := 'order by s3.sort_order limit 1'; v_rep := 'order by s3.due_date nulls last, s3.due_time nulls last, s3.sort_order limit 1';
    else
      v_old := 'order by s2.sort_order limit 1'; v_rep := 'order by s2.due_date nulls last, s2.due_time nulls last, s2.sort_order limit 1';
    end if;
    v_def := pg_get_functiondef(r.oid);
    if position(v_rep in v_def) > 0 then raise notice '% はすでに期限順です（何もしません）', r.proname; continue; end if;
    if (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 then raise exception '停止: % の並び順の指定が想定と違います（変えずに止めました）', r.proname; end if;
    v_new := replace(v_def, v_old, v_rep);
    execute v_new;
    raise notice '% を期限順に直しました', r.proname;
  end loop;
end $do$;

create or replace function public.hq_slack_step_reopen(p_slack_user_id text, p_step uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_u users%rowtype; v_s hq_task_steps%rowtype; v_t hq_tasks%rowtype;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  select u.* into v_u from user_slack s join users u on u.id = s.user_id where s.slack_user_id = p_slack_user_id and u.is_active;
  if v_u.id is null then return jsonb_build_object('ok', false, 'message', 'Slack が管理システムに紐づいていません'); end if;
  select * into v_s from hq_task_steps where id = p_step for update;
  if v_s.id is null then return jsonb_build_object('ok', false, 'message', '工程が見つかりません'); end if;
  select * into v_t from hq_tasks where id = v_s.task_id;
  if v_s.completed_at is null then return jsonb_build_object('ok', true, 'already', true, 'message', 'まだ完了していません（取り消す必要はありません）', 'task_id', v_s.task_id); end if;
  if not (v_u.id = v_s.completed_by or v_u.id = any(coalesce(v_s.assignee_ids, array[v_s.assignee_id])) or v_u.id = v_t.created_by or v_u.is_master or v_u.role in ('CEO', 'HQ')) then
    return jsonb_build_object('ok', false, 'message', '取り消せるのは、完了した本人・工程の担当者・タスクの作成者・本部だけです');
  end if;
  update hq_task_steps set completed_at = null, completed_by = null, judgement = null, issue_note = null where id = v_s.id;
  insert into hq_task_activity(task_id, step_id, actor_id, kind, detail) values (v_s.task_id, v_s.id, v_u.id, 'step_reopen', '工程「' || v_s.title || '」の完了を取り消し（Slack）');
  return jsonb_build_object('ok', true, 'task_id', v_s.task_id, 'step_title', v_s.title);
end $$;
revoke all on function public.hq_slack_step_reopen(text, uuid) from public, anon, authenticated;
grant execute on function public.hq_slack_step_reopen(text, uuid) to service_role;

create or replace function public.hq_slack_next_candidates()
returns table(recipient_id uuid, slack_user_id text, task_id uuid, task_title text, step_id uuid, step_title text, step_due date, kind text, days_over integer,
              prev_title text, prev_names text, prev_due date, url text)
language plpgsql security definer set search_path to 'public' as $$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if not public.hq_slack_is_service() then raise exception '権限がありません'; end if;
  return query
  with ranked as (
    select s.*, t.title as ttitle, coalesce(s.due_date, t.due_date) as eff_due,
           row_number() over (partition by s.task_id order by s.due_date nulls last, s.due_time nulls last, s.sort_order, s.id) as rn
      from hq_task_steps s join hq_tasks t on t.id = s.task_id
     where s.completed_at is null and t.status <> 'done' and t.deleted_at is null
  ), pair as (
    select c.task_id as tid, c.ttitle, c.id as cur_id, c.title as cur_title, c.eff_due as cur_due, coalesce(c.assignee_ids, case when c.assignee_id is not null then array[c.assignee_id] end, '{}'::uuid[]) as cur_who,
           n.id as nxt_id, n.title as nxt_title, n.eff_due as nxt_due, coalesce(n.assignee_ids, case when n.assignee_id is not null then array[n.assignee_id] end, '{}'::uuid[]) as nxt_who
      from ranked c left join ranked n on n.task_id = c.task_id and n.rn = 2
     where c.rn = 1
  ), a as (   -- 前の工程が止まっている（期限の当日／超過）→ 次の工程の担当者へ
    select p.tid, p.ttitle, p.nxt_id as sid, p.nxt_title as stitle, p.nxt_due as sdue,
           case when p.cur_due = v_today then 'next_today' when p.cur_due < v_today and ((v_today - p.cur_due) % 3) = 1 then 'next_over' end as k,
           greatest(v_today - p.cur_due, 0) as over, p.cur_title as ptitle, p.cur_due as pdue, p.cur_who as pwho,
           array(select x from unnest(p.nxt_who) x where not (x = any(p.cur_who))) as rcpt
      from pair p where p.nxt_id is not null and p.cur_due is not null
  ), b as (   -- 前の工程が完了した（最近）→ いまの工程の担当者へ「あなたの番です」
    select p.tid, p.ttitle, p.cur_id as sid, p.cur_title as stitle, p.cur_due as sdue, 'next_ready'::text as k, 0 as over,
           d.title as ptitle, d.eff_due as pdue, array[d.completed_by] as pwho,
           array(select x from unnest(p.cur_who) x where x is distinct from d.completed_by and not (x = any(coalesce(d.assignee_ids, array[d.assignee_id], '{}'::uuid[])))) as rcpt
      from pair p
      join lateral (select s2.*, coalesce(s2.due_date, t2.due_date) as eff_due from hq_task_steps s2 join hq_tasks t2 on t2.id = s2.task_id where s2.task_id = p.tid and s2.completed_at is not null order by s2.completed_at desc limit 1) d on true
     where d.completed_at >= now() - interval '36 hours'
  ), allk as (
    select * from a where k is not null
    union all
    select * from b
  ), ex as (
    select k2.tid, k2.ttitle, k2.sid, k2.stitle, k2.sdue, k2.k, k2.over, k2.ptitle, k2.pdue, k2.pwho, r as rid from allk k2, unnest(k2.rcpt) r
  )
  select e.rid, us.slack_user_id, e.tid, e.ttitle, e.sid, e.stitle, e.sdue, e.k, e.over,
         e.ptitle,
         (select string_agg(replace(replace(u2.name, ' ', ''), '　', ''), '・') from users u2 where u2.id = any(e.pwho)),
         e.pdue,
         'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || e.tid
    from ex e
    join users u on u.id = e.rid and u.is_active
    join user_slack us on us.user_id = e.rid
   where not exists (select 1 from hq_slack_reminder_log l where l.step_id = e.sid and l.recipient_id = e.rid and l.kind = e.k and (l.sent_on = v_today or e.k in ('next_today', 'next_ready')))
   order by e.pdue nulls last, e.tid;
end $$;
revoke all on function public.hq_slack_next_candidates() from public, anon, authenticated;
grant execute on function public.hq_slack_next_candidates() to service_role;

-- 設定: 最初は OFF（試し送り・件数の確認のあとで ON にする）
update app_settings set value = value || '{"next_notice_enabled": false}'::jsonb where key = 'hq_task_slack' and not (value ? 'next_notice_enabled');
