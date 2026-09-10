-- 2026-09-10（担当E）本部タスクに「最重要（急ぎ）」フラグを追加
--
-- ユーザー要望: 「急ぎのタスクに関しては最重要でわかるように、1番上に出てくるように
-- とアラートも出すようにしてほしい！単発タスクとか、今あるタスクにも最重要タスクみたいな
-- 形を押せるボタンを作って欲しい！絶対漏れないように」
--
-- 設計方針: タスク単位（工程単位ではない）で「最重要」フラグを持つ。誰が・いつ最重要に
-- したかも記録する（他の担当が「なぜこれが最重要になっているのか」を後から追えるように）。
-- 通知は既存のhq_notify_step_event/hq_check_alertsと同じ仕組み（個人チャットワークへは
-- 常に送る・任意で登録した通知ルールがあればlark/chatworkの共有チャンネルにも送る）を流用。

alter table hq_tasks add column if not exists is_urgent boolean not null default false;
alter table hq_tasks add column if not exists urgent_marked_by uuid references users(id);
alter table hq_tasks add column if not exists urgent_marked_at timestamptz;

-- 最重要にした瞬間の通知（工程完了時のhq_notify_step_eventと同じ形のテーブルを返す関数）
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
      v_personal := hq_personal_chatwork_room(v_r);
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

-- 「最重要」の切替そのもの。hq_tasks の直接UPDATEはhqt_updateポリシー(hq_can_manage()のみ)に
-- 阻まれるため、担当者・依頼者も押せるようにする分はこのSECURITY DEFINER関数側で権限判定する
create or replace function hq_set_task_urgent(p_task_id uuid, p_urgent boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_task record; v_cur record; v_allowed boolean;
begin
  select * into v_task from hq_tasks where id = p_task_id and deleted_at is null;
  if v_task is null then
    raise exception 'タスクが見つかりません';
  end if;
  select s.* into v_cur from hq_task_steps s where s.task_id = p_task_id and s.completed_at is null order by s.sort_order limit 1;
  v_allowed := hq_can_manage()
    or v_task.created_by = auth.uid()
    or (v_cur is not null and (v_cur.assignee_id = auth.uid() or auth.uid() = any(v_cur.assignee_ids)));
  if not v_allowed then
    raise exception '権限がありません';
  end if;
  update hq_tasks set is_urgent = p_urgent,
    urgent_marked_by = case when p_urgent then auth.uid() else null end,
    urgent_marked_at = case when p_urgent then now() else null end
  where id = p_task_id;
end;
$$;

grant execute on function hq_set_task_urgent(uuid, boolean) to authenticated;
