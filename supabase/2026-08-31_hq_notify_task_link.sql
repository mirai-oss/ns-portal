-- ============================================================
-- 本部タスク: 通知メッセージ（Lark/Chatwork）にタスクへの直接リンクを追加
-- 作成: 2026-08-31 ／ 担当E（本部タスクボード）
--
-- ユーザー要望: 「期限前に通知は来るけど、そのタスクのURLが付いてなくてすぐ確認できない。
-- 通知のリンクを開けばそのタスクへ行けるようにしてほしい」
--
-- 対応: 外部通知（Lark Webhook・Chatwork）のメッセージ本文の末尾に、そのタスクを直接開ける
-- URL（https://mirai-oss.github.io/ns-portal/tasks.html?task=<id>）を1行追加する。
-- アプリ内通知（hq_notifications）は既にtask_id列を持っておりクリックでopenDetail()する
-- 仕組みが既にあるため変更しない（今回は外部通知の本文だけの変更）。
--
-- 既存ロジック（誰に・いつ・どのイベントで送るか）は一切変えず、Deno Editor上で確認した
-- 本番の関数定義（pg_get_functiondef）をベースに、本文末尾へのURL追記のみ追加している。
-- ============================================================

create or replace function hq_check_alerts()
returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $function$
declare
  v_today date := current_date;
  v_task record;
  v_cur record;
  v_alert record;
  v_recipient uuid;
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
      v_recipient := coalesce(v_cur.assignee_id, v_task.created_by);
      if v_recipient is not null then
        insert into hq_notifications(recipient_id, task_id, kind, title, body) values (v_recipient, v_task.id, 'due_alert', v_title, coalesce(v_cur.title,''));
        v_personal := hq_personal_chatwork_room(v_recipient);
        if v_personal is not null then
          v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || v_title; v_bodies := v_bodies || (coalesce(v_cur.title,'') || E'\n' || v_url);
        end if;
      end if;
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
      v_recipient := coalesce(v_cur.assignee_id, v_task.created_by);
      if v_recipient is not null then
        insert into hq_notifications(recipient_id, task_id, kind, title, body) values (v_recipient, v_task.id, 'stalled', '停滞: ' || v_task.title, v_stalled_days || '日停止');
        v_personal := hq_personal_chatwork_room(v_recipient);
        if v_personal is not null then
          v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || ('停滞: '||v_task.title); v_bodies := v_bodies || ((v_stalled_days || '日停止') || E'\n' || v_url);
        end if;
      end if;
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
$function$;

create or replace function hq_notify_step_event(p_step_id uuid, p_event text)
returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $function$
declare
  v_step record; v_task record; v_next record;
  v_title text; v_body text; v_recipient uuid; v_personal text;
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
    if v_next is not null and v_next.assignee_id is not null then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_next.assignee_id, v_task.id, 'step_complete', 'あなたの番です: '||v_task.title, v_next.title||'をお願いします');
      v_recipient := v_next.assignee_id; v_title := 'あなたの番です: '||v_task.title; v_body := v_next.title||'をお願いします';
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

  if v_recipient is not null then
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
$function$;

create or replace function hq_notify_comment(p_comment_id uuid)
returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $function$
declare
  v_com record; v_task record; v_uid uuid;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_ch record; v_cw text; v_title text; v_body text; v_uname text; v_personal text;
  v_url text;
begin
  select * into v_com from hq_task_comments where id = p_comment_id;
  if v_com is null then return; end if;
  select * into v_task from hq_tasks where id = v_com.task_id;
  if v_task is null then return; end if;
  v_url := 'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || v_task.id;
  v_title := 'メンションされました: ' || v_task.title;

  foreach v_uid in array coalesce(v_com.mentions, '{}') loop
    if v_uid <> v_com.created_by then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_uid, v_task.id, 'mention', v_title, v_com.body);

      select account_id into v_cw from hq_user_chatwork where user_id = v_uid;
      select name into v_uname from users where id = v_uid;
      v_body := (case when v_cw is not null then '[To:'||v_cw||']' else coalesce(v_uname,'') end) || ' ' || v_com.body || E'\n' || v_url;

      v_personal := hq_personal_chatwork_room(v_uid);
      if v_personal is not null then
        v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text;
        v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
      end if;

      for v_ch in
        select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
        join hq_notify_channels c on c.id = any(r.channel_ids)
        where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event='mention'
          and (r.target_corp is null or r.target_corp=v_task.corp)
          and (r.target_freq is null or r.target_freq=v_task.freq)
          and (r.target_template_id is null or r.target_template_id=v_task.template_id)
      loop
        v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,'');
        v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
      end loop;
    end if;
  end loop;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$function$;
