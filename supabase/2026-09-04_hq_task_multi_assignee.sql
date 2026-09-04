-- 2026-09-04（担当E）本部タスクの工程に複数担当者を設定できるようにする
--
-- ユーザー要望: 「タスクの担当者を複数人、選べるようにしてほしい！どの担当者でもその工程が
-- 完了したら、他の担当者も完了になるようにはしてほしい。目的=その担当者がいない場合でも、
-- 他の人が自分の担当タスクとして表示されるようにして、他の人でもカバーできるようにするため」
--
-- 設計方針:
-- ・「工程が完了したら他の担当者も完了になる」は、工程=1行・完了状態も1行分の
--   completed_at/completed_byで持つ既存の作りのままで自動的に満たされる（誰か1人が完了させれば
--   その工程は完了。特別な同期処理は不要）。今回必要なのは「複数人のうち誰でも完了操作できる」
--   という権限面の拡張
-- ・既存のassignee_id（単数）列は残し、新設のassignee_ids（配列）と常に同期させるトリガーを追加。
--   理由: ポータル側(index.html/portal.html)の「自分のタスク」バッジ・一覧が
--   cur.assignee_id===ctx.u.id という単数比較で作られており（担当E管轄外のファイル）、
--   assignee_idを主担当として残すことでその機能を壊さない後方互換を保つ。ただし2人目以降の
--   担当者はポータル側バッジには出ない制限が残る点はWORKLOGで申し送りする

-- 1. 複数担当者を保持する配列列を追加（工程本体・テンプレート工程の両方）
alter table hq_task_steps add column if not exists assignee_ids uuid[];
alter table hq_task_template_steps add column if not exists assignee_ids uuid[];

update hq_task_steps set assignee_ids = array[assignee_id] where assignee_id is not null and assignee_ids is null;
update hq_task_template_steps set assignee_ids = array[assignee_id] where assignee_id is not null and assignee_ids is null;

-- 2. assignee_id/assignee_idsを常に同期させるトリガー（hq_task_steps側。どちらの列を
--    書いても矛盾しない状態を保つ。assignee_ids優先＝先頭要素を主担当としてassignee_idへ反映）
create or replace function hq_task_step_sync_assignees() returns trigger
language plpgsql as $$
begin
  if (new.assignee_ids is null or array_length(new.assignee_ids,1) is null) and new.assignee_id is not null then
    new.assignee_ids := array[new.assignee_id];
  end if;
  if new.assignee_ids is not null and array_length(new.assignee_ids,1) is not null then
    new.assignee_id := new.assignee_ids[1];
  else
    new.assignee_id := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_hq_task_step_sync_assignees on hq_task_steps;
create trigger trg_hq_task_step_sync_assignees
  before insert or update on hq_task_steps
  for each row execute function hq_task_step_sync_assignees();

-- 3. 編集権限トリガーにassignee_idsも追加（非管理者がassignee_idを迂回してassignee_idsだけ
--    書き換えられてしまわないように、既存のassignee_idガードと同列で守る）
create or replace function hq_task_step_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not hq_can_manage() then
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
$$;

-- 4. RLS更新ポリシーに「assignee_idsに自分が含まれる場合」を追加
--    （これが無いと、複数担当者のうち先頭（主担当）以外の人が工程を完了・編集できず、
--    今回の目的そのものが満たせない）
alter policy hqs_update on hq_task_steps
  using (hq_can_manage() or assignee_id = auth.uid() or auth.uid() = any(assignee_ids) or (assignee_id is null and hq_task_visible(task_id)))
  with check (hq_can_manage() or assignee_id = auth.uid() or auth.uid() = any(assignee_ids) or (assignee_id is null and hq_task_visible(task_id)));

-- 5. 工程内チェックリストの更新ポリシーも同様に対応
create or replace function hq_step_checklist_can_write(p_step_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from hq_task_steps s
    where s.id = p_step_id
      and (hq_can_manage() or s.assignee_id = auth.uid() or auth.uid() = any(s.assignee_ids)
           or (s.assignee_id is null and hq_task_visible(s.task_id)))
  );
$$;

alter policy hqscl_step_write on hq_step_checklist_items
  using (step_id is not null and hq_step_checklist_can_write(step_id))
  with check (step_id is not null and hq_step_checklist_can_write(step_id));

-- 6. タスクの可視性判定に「assignee_idsに自分が含まれる工程がある」を追加
--    （これが無いと2人目以降の担当者はそもそもタスク自体を見られない＝一覧に出てこない）
create or replace function hq_task_visible(t_id uuid)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $$
  select coalesce((
    select
      hq_can_manage()
      or (t.visibility = 'all'
          and exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.role = 'TEAM'))
      or exists (select 1 from hq_task_members m where m.task_id = t.id and m.user_id = auth.uid())
      or (t.template_id is not null
          and exists (select 1 from hq_task_members m where m.template_id = t.template_id and m.user_id = auth.uid()))
      or exists (select 1 from hq_task_steps s where s.task_id = t.id and (s.assignee_id = auth.uid() or auth.uid() = any(s.assignee_ids)))
    from hq_tasks t where t.id = t_id
  ), false);
$$;

create or replace function hq_task_visible_self(t_id uuid, t_visibility text, t_template_id uuid)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $$
  select
    hq_can_manage()
    or (t_visibility = 'all'
        and exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.role = 'TEAM'))
    or exists (select 1 from hq_task_members m where m.task_id = t_id and m.user_id = auth.uid())
    or (t_template_id is not null
        and exists (select 1 from hq_task_members m where m.template_id = t_template_id and m.user_id = auth.uid()))
    or exists (select 1 from hq_task_steps s where s.task_id = t_id and (s.assignee_id = auth.uid() or auth.uid() = any(s.assignee_ids)));
$$;

-- 7. テンプレートからの自動生成・手動生成で、テンプレート工程のassignee_idsを引き継ぐ
create or replace function hq_generate_today() returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_today date := current_date;
  v_dow int := extract(dow from v_today)::int;
  v_dom int := extract(day from v_today)::int;
  v_tpl record;
  v_task_id uuid;
  v_step record;
  v_store record;
  v_new_step_id uuid;
  v_count int := 0;
  v_title text;
begin
  for v_tpl in
    select * from hq_task_templates
    where is_active
      and (
        freq = 'daily'
        or (freq = 'weekly' and weekly_dow = v_dow)
        or (freq = 'monthly' and monthly_dom = v_dom)
      )
  loop
    v_title := case when v_tpl.freq = 'monthly' then (extract(month from v_today)::int || '月分 ' || v_tpl.title) else v_tpl.title end;

    insert into hq_tasks (template_id, title, corp, freq, target_date, due_date, due_time, notes, description, visibility, created_by)
    values (v_tpl.id, v_title, v_tpl.corp, v_tpl.freq, v_today, v_today + v_tpl.due_offset_days, v_tpl.due_time, v_tpl.notes, v_tpl.description, v_tpl.visibility, v_tpl.created_by)
    on conflict (template_id, target_date) do nothing
    returning id into v_task_id;

    if v_task_id is null then
      continue;
    end if;
    v_count := v_count + 1;

    for v_step in select * from hq_task_template_steps where template_id = v_tpl.id order by sort_order loop
      if v_step.kind = 'check' and v_step.store_scope is not null then
        for v_store in
          select id from stores where
            case
              when v_step.store_ids is not null and array_length(v_step.store_ids,1) > 0 then id = any(v_step.store_ids)
              else (v_step.store_scope = 'all' or is_active)
            end
          order by sort_order
        loop
          insert into hq_task_steps(task_id, template_step_id, title, assignee_id, assignee_ids, due_date, due_time, sort_order, kind, is_binary, requires_photo, store_id, procedure_note)
          values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_step.assignee_ids, v_today + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_store.id, v_step.procedure_note)
          returning id into v_new_step_id;
          insert into hq_step_checklist_items(step_id, title, sort_order)
            select v_new_step_id, ci.title, ci.sort_order
            from hq_step_checklist_items ci where ci.template_step_id = v_step.id order by ci.sort_order;
        end loop;
      else
        insert into hq_task_steps(task_id, template_step_id, title, assignee_id, assignee_ids, due_date, due_time, sort_order, kind, is_binary, requires_photo, procedure_note)
        values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_step.assignee_ids, v_today + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_step.procedure_note)
        returning id into v_new_step_id;
        insert into hq_step_checklist_items(step_id, title, sort_order)
          select v_new_step_id, ci.title, ci.sort_order
          from hq_step_checklist_items ci where ci.template_step_id = v_step.id order by ci.sort_order;
      end if;
    end loop;

    insert into hq_task_activity(task_id, actor_id, kind, detail)
    values (v_task_id, null, 'create', '自動生成（' || v_tpl.freq || '）');
  end loop;

  if v_count > 0 then
    insert into hq_generation_log(work_date, generated_by, task_count) values (v_today, auth.uid(), v_count)
      on conflict (work_date) do update set task_count = hq_generation_log.task_count + excluded.task_count, generated_at = now();
  end if;
  return v_count;
end;
$$;

create or replace function hq_create_from_template(p_template_id uuid, p_target_date date default null)
returns table(task_id uuid, was_created boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_tpl record;
  v_date date := coalesce(p_target_date, current_date);
  v_task_id uuid;
  v_step record;
  v_store record;
  v_new_step_id uuid;
  v_title text;
begin
  if not hq_feature_allowed('newtask') then
    raise exception 'タスクを追加する権限がありません';
  end if;

  select * into v_tpl from hq_task_templates where id = p_template_id;
  if v_tpl is null then
    raise exception 'テンプレートが見つかりません';
  end if;

  v_title := case when v_tpl.freq = 'monthly' then (extract(month from v_date)::int || '月分 ' || v_tpl.title) else v_tpl.title end;

  insert into hq_tasks (template_id, title, corp, freq, target_date, due_date, due_time, notes, description, visibility, created_by)
  values (v_tpl.id, v_title, v_tpl.corp, v_tpl.freq, v_date, v_date + v_tpl.due_offset_days, v_tpl.due_time,
          v_tpl.notes, v_tpl.description, v_tpl.visibility, coalesce(auth.uid(), v_tpl.created_by))
  on conflict (template_id, target_date) do nothing
  returning id into v_task_id;

  if v_task_id is null then
    select t.id into v_task_id from hq_tasks t where t.template_id = v_tpl.id and t.target_date = v_date;
    return query select v_task_id, false;
    return;
  end if;

  for v_step in select * from hq_task_template_steps where template_id = v_tpl.id order by sort_order loop
    if v_step.kind = 'check' and v_step.store_scope is not null then
      for v_store in
        select id from stores where
          case
            when v_step.store_ids is not null and array_length(v_step.store_ids,1) > 0 then id = any(v_step.store_ids)
            else (v_step.store_scope = 'all' or is_active)
          end
        order by sort_order
      loop
        insert into hq_task_steps(task_id, template_step_id, title, assignee_id, assignee_ids, due_date, due_time, sort_order, kind, is_binary, requires_photo, store_id, procedure_note)
        values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_step.assignee_ids, v_date + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_store.id, v_step.procedure_note)
        returning id into v_new_step_id;
        insert into hq_step_checklist_items(step_id, title, sort_order)
          select v_new_step_id, ci.title, ci.sort_order
          from hq_step_checklist_items ci where ci.template_step_id = v_step.id order by ci.sort_order;
      end loop;
    else
      insert into hq_task_steps(task_id, template_step_id, title, assignee_id, assignee_ids, due_date, due_time, sort_order, kind, is_binary, requires_photo, procedure_note)
      values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_step.assignee_ids, v_date + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_step.procedure_note)
      returning id into v_new_step_id;
      insert into hq_step_checklist_items(step_id, title, sort_order)
        select v_new_step_id, ci.title, ci.sort_order
        from hq_step_checklist_items ci where ci.template_step_id = v_step.id order by ci.sort_order;
    end if;
  end loop;

  insert into hq_task_activity(task_id, actor_id, kind, detail)
  values (v_task_id, auth.uid(), 'create', 'テンプレートから手動追加（対象日 ' || to_char(v_date,'YYYY-MM-DD') || '）');

  return query select v_task_id, true;
end;
$$;

-- 8. 通知の送信先を「複数担当者全員」に拡張（1人にしか届かないと、担当を外れた/いない人の
--    カバー役に何も通知が行かず、今回の目的が実質満たせないため）
create or replace function hq_check_alerts()
returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
declare
  v_today date := current_date;
  v_task record;
  v_cur record;
  v_alert record;
  v_recipients uuid[];
  v_r uuid;
  v_event text;
  v_title text;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_ch record;
  v_personal text;
  v_stalled_days int;
  v_since timestamptz;
  v_url text;
begin
  for v_task in select t.* from hq_tasks t where t.status <> 'done' loop
    v_url := 'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || v_task.id;
    select s.* into v_cur from hq_task_steps s where s.task_id=v_task.id and s.completed_at is null order by s.sort_order limit 1;
    if v_cur is null then continue; end if;

    select * into v_alert from hq_task_alerts where task_id = v_task.id;
    v_event := null; v_title := null;
    v_recipients := coalesce(v_cur.assignee_ids, case when v_cur.assignee_id is not null then array[v_cur.assignee_id] else null end, array[v_task.created_by]);

    if v_cur.due_date is not null then
      if v_cur.due_date < v_today and coalesce(v_alert.overdue_daily, (select alert_overdue_daily from hq_task_templates where id=v_task.template_id), true) then
        v_event := 'due_alert'; v_title := '期限超過: ' || v_task.title;
      elsif v_cur.due_date = v_today and coalesce(v_alert.due, (select alert_due from hq_task_templates where id=v_task.template_id), true) then
        v_event := 'due_alert'; v_title := '本日期限: ' || v_task.title;
      elsif v_cur.due_date = v_today + 1 and coalesce(v_alert.before1, (select alert_before1 from hq_task_templates where id=v_task.template_id), true) then
        v_event := 'due_alert'; v_title := '明日期限: ' || v_task.title;
      elsif v_cur.due_date = v_today + 3 and coalesce(v_alert.before3, (select alert_before3 from hq_task_templates where id=v_task.template_id), true) then
        v_event := 'due_alert'; v_title := '期限3日前: ' || v_task.title;
      end if;
    end if;

    if v_event is not null and not exists(
      select 1 from hq_notifications n where n.task_id=v_task.id and n.kind='due_alert' and n.created_at::date = v_today
    ) then
      foreach v_r in array v_recipients loop
        if v_r is not null then
          insert into hq_notifications(recipient_id, task_id, kind, title, body) values (v_r, v_task.id, 'due_alert', v_title, coalesce(v_cur.title,''));
          v_personal := hq_personal_chatwork_room(v_r);
          if v_personal is not null then
            v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || v_title; v_bodies := v_bodies || (coalesce(v_cur.title,'') || E'\n' || v_url);
          end if;
        end if;
      end loop;
      for v_ch in
        select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
        join hq_notify_channels c on c.id = any(r.channel_ids)
        where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event='due_alert'
          and (r.target_corp is null or r.target_corp=v_task.corp)
          and (r.target_freq is null or r.target_freq=v_task.freq)
          and (r.target_template_id is null or r.target_template_id=v_task.template_id)
      loop
        v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || v_title; v_bodies := v_bodies || (coalesce(v_cur.title,'') || E'\n' || v_url);
      end loop;
    end if;

    select s.completed_at into v_since from hq_task_steps s where s.task_id=v_task.id and s.sort_order < v_cur.sort_order order by s.sort_order desc limit 1;
    if v_since is null then v_since := v_task.created_at; end if;
    v_stalled_days := floor(extract(epoch from (now() - v_since))/86400);
    if v_stalled_days >= 3 and coalesce(v_alert.overdue_daily, true) and not exists(
      select 1 from hq_notifications n where n.task_id=v_task.id and n.kind='stalled' and n.created_at::date = v_today
    ) then
      foreach v_r in array v_recipients loop
        if v_r is not null then
          insert into hq_notifications(recipient_id, task_id, kind, title, body) values (v_r, v_task.id, 'stalled', '停滞: ' || v_task.title, v_stalled_days || '日停止');
          v_personal := hq_personal_chatwork_room(v_r);
          if v_personal is not null then
            v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || ('停滞: '||v_task.title); v_bodies := v_bodies || ((v_stalled_days || '日停止') || E'\n' || v_url);
          end if;
        end if;
      end loop;
      for v_ch in
        select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
        join hq_notify_channels c on c.id = any(r.channel_ids)
        where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event='stalled'
          and (r.target_corp is null or r.target_corp=v_task.corp)
          and (r.target_freq is null or r.target_freq=v_task.freq)
          and (r.target_template_id is null or r.target_template_id=v_task.template_id)
      loop
        v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || ('停滞: '||v_task.title); v_bodies := v_bodies || ((v_stalled_days || '日停止') || E'\n' || v_url);
      end loop;
    end if;
  end loop;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$$;

create or replace function hq_notify_step_event(p_step_id uuid, p_event text)
returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
declare
  v_step record; v_task record; v_next record;
  v_title text; v_body text; v_recipient uuid; v_personal text;
  v_next_recipients uuid[]; v_r uuid;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_ch record;
  v_url text;
begin
  select * into v_step from hq_task_steps where id = p_step_id;
  if v_step is null then return; end if;
  select * into v_task from hq_tasks where id = v_step.task_id;
  if v_task is null then return; end if;
  v_url := 'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || v_task.id;
  v_recipient := null;

  if p_event = 'step_complete' then
    v_title := '工程完了: ' || v_task.title;
    v_body := v_step.title || ' が完了しました';
    select * into v_next from hq_task_steps where task_id=v_task.id and completed_at is null order by sort_order limit 1;
    if v_next is not null then
      v_next_recipients := coalesce(v_next.assignee_ids, case when v_next.assignee_id is not null then array[v_next.assignee_id] else null end);
      if v_next_recipients is not null and array_length(v_next_recipients,1) is not null then
        v_title := 'あなたの番です: '||v_task.title; v_body := v_next.title||'をお願いします';
        foreach v_r in array v_next_recipients loop
          if v_r is not null then
            insert into hq_notifications(recipient_id, task_id, kind, title, body)
            values (v_r, v_task.id, 'step_complete', v_title, v_body);
          end if;
        end loop;
      end if;
    end if;
  elsif p_event = 'issue_reported' then
    v_title := '異常あり: ' || v_task.title;
    v_body := v_step.title || ' — ' || coalesce(v_step.issue_note,'');
    if v_task.created_by is not null then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_task.created_by, v_task.id, 'issue_reported', v_title, v_body);
      v_recipient := v_task.created_by;
    end if;
  else
    return;
  end if;

  v_body := v_body || E'\n' || v_url;

  if p_event = 'step_complete' and v_next_recipients is not null then
    foreach v_r in array v_next_recipients loop
      if v_r is not null then
        v_personal := hq_personal_chatwork_room(v_r);
        if v_personal is not null then
          v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
        end if;
      end if;
    end loop;
  elsif v_recipient is not null then
    v_personal := hq_personal_chatwork_room(v_recipient);
    if v_personal is not null then
      v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
    end if;
  end if;

  for v_ch in
    select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
    join hq_notify_channels c on c.id = any(r.channel_ids)
    where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event=p_event
      and (r.target_corp is null or r.target_corp=v_task.corp)
      and (r.target_freq is null or r.target_freq=v_task.freq)
      and (r.target_template_id is null or r.target_template_id=v_task.template_id)
  loop
    v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
  end loop;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$$;
