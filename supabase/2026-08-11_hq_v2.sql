-- ============================================================
-- 本部タスクボード 改善v2（実装指示書v2・14項目対応）
-- 対象: hq_ テーブルのみ変更。既存テーブル・manual_itemsは読取専用。
-- 冪等。
-- ============================================================

-- ---- B-3: タスク削除は作成者のみ（RLSで強制） ----
-- 従来はhq_can_manage()（マスター/社長/本部）なら誰でも削除可だったが、
-- 「削除できるのは作成者だけ」という要求に合わせて限定。
-- テンプレから自動生成されたタスクの created_by はテンプレ作成者
-- （hq_generate_today内でそのまま引き継いでいるので追加対応不要）。
drop policy if exists hqt_delete on hq_tasks;
create policy hqt_delete on hq_tasks for delete using (created_by = auth.uid());

-- ============================================================
-- C-1: タスク内コメント＋@メンション＋通知
-- ============================================================
create table if not exists hq_task_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references hq_tasks(id) on delete cascade,
  body text not null,
  mentions uuid[] not null default '{}',
  created_by uuid references users(id),
  created_at timestamptz not null default now()
);
create index if not exists hq_task_comments_task_idx on hq_task_comments (task_id, created_at);

alter table hq_task_comments enable row level security;
drop policy if exists hqcom_read on hq_task_comments;
create policy hqcom_read on hq_task_comments for select using (hq_task_visible(task_id));
drop policy if exists hqcom_insert on hq_task_comments;
create policy hqcom_insert on hq_task_comments for insert with check (hq_task_visible(task_id) and created_by = auth.uid());
drop policy if exists hqcom_delete on hq_task_comments;
create policy hqcom_delete on hq_task_comments for delete using (created_by = auth.uid());

-- hq_notifications.kind に 'mention' を追加（既存3d-3で作成したCHECK制約を作り直し）
alter table hq_notifications drop constraint if exists hq_notifications_kind_check;
alter table hq_notifications add constraint hq_notifications_kind_check
  check (kind in ('due_alert','stalled','step_complete','issue_reported','mention'));

-- コメント投稿の直後にクライアントから呼ぶ。メンション先へアプリ内通知を作成し、
-- （C-2実装後は）Chatworkの送信対象も戻り値で返す。
create or replace function hq_notify_comment(p_comment_id uuid) returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
declare
  v_com record; v_task record; v_uid uuid;
begin
  select * into v_com from hq_task_comments where id = p_comment_id;
  if v_com is null then return; end if;
  select * into v_task from hq_tasks where id = v_com.task_id;
  if v_task is null then return; end if;

  foreach v_uid in array coalesce(v_com.mentions, '{}') loop
    if v_uid <> v_com.created_by then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_uid, v_task.id, 'mention', 'メンションされました: '||v_task.title, v_com.body);
    end if;
  end loop;

  return query select null::text, null::text, null::text, null::text, null::text where false;
end;
$$;

-- ============================================================
-- C-2: Chatwork通知チャンネル（Edge Function中継。実送信はnotify-chatwork
-- Edge Functionを経由。トークンはsupabase secretsに保存しクライアントには
-- 一切渡さない）
-- ============================================================
alter table hq_notify_channels add column if not exists room_id text;
alter table hq_notify_channels drop constraint if exists hq_notify_channels_kind_check;
alter table hq_notify_channels add constraint hq_notify_channels_kind_check
  check (kind in ('lark_webhook','inapp','chatwork'));

-- 個人のChatworkアカウントID（メンション用 [To:id]）。usersはALTER禁止のため新設。
create table if not exists hq_user_chatwork (
  user_id uuid primary key references users(id) on delete cascade,
  account_id text not null,
  updated_at timestamptz not null default now()
);
alter table hq_user_chatwork enable row level security;
drop policy if exists hquc_read on hq_user_chatwork;
create policy hquc_read on hq_user_chatwork for select using (auth.uid() is not null);
drop policy if exists hquc_write on hq_user_chatwork;
create policy hquc_write on hq_user_chatwork for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ---- 通知関数を統一形式（channel_kind, target, keyword, title, body）に変更 ----
-- target: lark_webhook=webhook_url ／ chatwork=room_id
drop function if exists hq_check_alerts();
create function hq_check_alerts() returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
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
  v_stalled_days int;
  v_since timestamptz;
begin
  for v_task in select t.* from hq_tasks t where t.status <> 'done' loop
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
      end if;
      for v_ch in
        select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
        join hq_notify_channels c on c.id = any(r.channel_ids)
        where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event='due_alert'
          and (r.target_corp is null or r.target_corp=v_task.corp)
          and (r.target_freq is null or r.target_freq=v_task.freq)
          and (r.target_template_id is null or r.target_template_id=v_task.template_id)
      loop
        v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || v_title; v_bodies := v_bodies || coalesce(v_cur.title,'');
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
      end if;
      for v_ch in
        select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
        join hq_notify_channels c on c.id = any(r.channel_ids)
        where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event='stalled'
          and (r.target_corp is null or r.target_corp=v_task.corp)
          and (r.target_freq is null or r.target_freq=v_task.freq)
          and (r.target_template_id is null or r.target_template_id=v_task.template_id)
      loop
        v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || ('停滞: '||v_task.title); v_bodies := v_bodies || (v_stalled_days || '日停止');
      end loop;
    end if;
  end loop;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$$;

drop function if exists hq_notify_step_event(uuid, text);
create function hq_notify_step_event(p_step_id uuid, p_event text) returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
declare
  v_step record; v_task record; v_next record;
  v_title text; v_body text;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_ch record;
begin
  select * into v_step from hq_task_steps where id = p_step_id;
  if v_step is null then return; end if;
  select * into v_task from hq_tasks where id = v_step.task_id;
  if v_task is null then return; end if;

  if p_event = 'step_complete' then
    v_title := '工程完了: ' || v_task.title;
    v_body := v_step.title || ' が完了しました';
    select * into v_next from hq_task_steps where task_id=v_task.id and completed_at is null order by sort_order limit 1;
    if v_next is not null and v_next.assignee_id is not null then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_next.assignee_id, v_task.id, 'step_complete', 'あなたの番です: '||v_task.title, v_next.title||'をお願いします');
    end if;
  elsif p_event = 'issue_reported' then
    v_title := '異常あり: ' || v_task.title;
    v_body := v_step.title || ' — ' || coalesce(v_step.issue_note,'');
    if v_task.created_by is not null then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_task.created_by, v_task.id, 'issue_reported', v_title, v_body);
    end if;
  else
    return;
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

-- 通知ルールのイベント種別に 'mention' を追加
alter table hq_notify_rules drop constraint if exists hq_notify_rules_event_check;
alter table hq_notify_rules add constraint hq_notify_rules_event_check
  check (event in ('due_alert','stalled','step_complete','issue_reported','mention'));

-- コメントのメンション通知も統一形式に更新（chatworkは対象者のアカウントIDが
-- 登録済みなら[To:id]付きで本文を組む。未登録なら宛先名をそのまま書く）
create or replace function hq_notify_comment(p_comment_id uuid) returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
declare
  v_com record; v_task record; v_uid uuid;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_ch record; v_cw text; v_title text; v_body text; v_uname text;
begin
  select * into v_com from hq_task_comments where id = p_comment_id;
  if v_com is null then return; end if;
  select * into v_task from hq_tasks where id = v_com.task_id;
  if v_task is null then return; end if;
  v_title := 'メンションされました: ' || v_task.title;

  foreach v_uid in array coalesce(v_com.mentions, '{}') loop
    if v_uid <> v_com.created_by then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_uid, v_task.id, 'mention', v_title, v_com.body);

      select account_id into v_cw from hq_user_chatwork where user_id = v_uid;
      select name into v_uname from users where id = v_uid;
      v_body := (case when v_cw is not null then '[To:'||v_cw||']' else coalesce(v_uname,'') end) || ' ' || v_com.body;

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
