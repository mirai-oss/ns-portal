-- 2026-09-29（担当E）個人Chatwork通知を出来事ごとに複数の部屋へ振り分けられるようにする
--
-- ユーザー要望: 「メンションされた時だけに通知する場所と、複数選択して、その他の通知をする
-- 場所と2つに分けたい」「経費申請とかも同じチャットルームに来てしまうから整理したい」
--
-- 設計方針:
-- ・既存のhq_user_chatwork.room_id（1人1部屋）はそのまま残す。経費申請
--   （expense_submit等・担当E管轄外）はこれまでどおりhq_personal_chatwork_room(uuid)を
--   直接呼び続けており、今回の変更では一切触れない＝経費申請の通知先は変わらない
-- ・本部タスク側（担当Eの4つの通知関数）だけ、新しい2引数版の関数へ切り替える。
--   その関数は「出来事に合ったルートがあればそこへ／無ければキャッチオールのルートへ／
--   それも無ければ従来のhq_user_chatworkへ」の順に探す設計にする

-- 1. 出来事ごとの行き先テーブル（1人が複数行持てる）
create table if not exists hq_user_notify_routes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  room_id text not null,
  events text[] not null default '{}',
  label text,
  sort_order int not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_hq_user_notify_routes_user on hq_user_notify_routes(user_id);

alter table hq_user_notify_routes enable row level security;

-- hq_user_chatworkと同じ考え方（読み取りはログイン済みなら誰でも・書き込みは本人のみ）
drop policy if exists hqunr_read on hq_user_notify_routes;
create policy hqunr_read on hq_user_notify_routes for select using (auth.uid() is not null);
drop policy if exists hqunr_write on hq_user_notify_routes;
create policy hqunr_write on hq_user_notify_routes for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 2. 出来事に応じた行き先を返す関数（既存のhq_personal_chatwork_room(uuid)は一切変更しない。
--    経費申請などの既存呼び出し元はそのまま従来どおり動く）
create or replace function hq_personal_chatwork_room_for_event(p_user_id uuid, p_event text)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_room text;
begin
  -- ①そのイベントを明示的に含むルートを最優先
  select room_id into v_room from hq_user_notify_routes
    where user_id = p_user_id and p_event = any(events)
    order by sort_order limit 1;
  if v_room is not null then return v_room; end if;

  -- ②次に「その他すべて」ルート（events が空配列＝キャッチオール）
  select room_id into v_room from hq_user_notify_routes
    where user_id = p_user_id and coalesce(array_length(events,1),0) = 0
    order by sort_order limit 1;
  if v_room is not null then return v_room; end if;

  -- ③どちらも無ければ、従来どおりの単一ルーム設定（hq_user_chatwork）にフォールバック
  return (select room_id from hq_user_chatwork where user_id = p_user_id and room_id is not null);
end;
$$;

-- 3. 担当Eの4つの通知関数を、新しい2引数版（イベント名つき）を使うように更新する。
--    hq_personal_chatwork_room(uuid) 呼び出しを hq_personal_chatwork_room_for_event(uuid,'event名')
--    へ差し替えただけで、ロジックのそれ以外の部分は変更していない

create or replace function hq_notify_comment(p_comment_id uuid)
returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
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

      v_personal := hq_personal_chatwork_room_for_event(v_uid, 'mention');
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
$$;

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
          v_personal := hq_personal_chatwork_room_for_event(v_r, 'due_alert');
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
          v_personal := hq_personal_chatwork_room_for_event(v_r, 'stalled');
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
        v_personal := hq_personal_chatwork_room_for_event(v_r, 'step_complete');
        if v_personal is not null then
          v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
        end if;
      end if;
    end loop;
  elsif v_recipient is not null then
    v_personal := hq_personal_chatwork_room_for_event(v_recipient, p_event);
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

create or replace function hq_notify_task_urgent(p_task_id uuid)
returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
declare
  v_task record; v_cur record;
  v_recipients uuid[]; v_r uuid;
  v_title text; v_body text; v_url text; v_personal text;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_ch record;
begin
  select * into v_task from hq_tasks where id = p_task_id;
  if v_task is null then return; end if;
  v_url := 'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || v_task.id;
  v_title := '🔥最重要: ' || v_task.title;

  select s.* into v_cur from hq_task_steps s where s.task_id = v_task.id and s.completed_at is null order by s.sort_order limit 1;
  v_body := (case when v_cur is not null then 'いま: ' || v_cur.title else '' end) || E'\n' || v_url;

  v_recipients := coalesce(v_cur.assignee_ids, case when v_cur.assignee_id is not null then array[v_cur.assignee_id] else null end, '{}'::uuid[]);
  if v_task.created_by is not null and not (v_task.created_by = any(v_recipients)) then
    v_recipients := v_recipients || v_task.created_by;
  end if;

  foreach v_r in array v_recipients loop
    if v_r is not null then
      insert into hq_notifications(recipient_id, task_id, kind, title, body) values (v_r, v_task.id, 'task_urgent', v_title, coalesce(v_cur.title,''));
      v_personal := hq_personal_chatwork_room_for_event(v_r, 'task_urgent');
      if v_personal is not null then
        v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
      end if;
    end if;
  end loop;

  for v_ch in
    select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
    join hq_notify_channels c on c.id = any(r.channel_ids)
    where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event='task_urgent'
      and (r.target_corp is null or r.target_corp=v_task.corp)
      and (r.target_freq is null or r.target_freq=v_task.freq)
      and (r.target_template_id is null or r.target_template_id=v_task.template_id)
  loop
    v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
  end loop;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$$;
