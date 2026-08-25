-- ============================================================
-- E-3(B7): 工程の中に入れ子のチェックリスト（手順）を追加
-- 作成: 2026-08-25 ／ 担当E（本部タスクボード改善）
--
-- 既存の「1行=1工程」という hq_task_template_steps / hq_task_steps の構造は
-- 変えず、新規テーブル hq_step_checklist_items を追加するだけ（追加のみ）。
-- テンプレート側（template_step_id）でチェック項目のひな形を定義すると、
-- hq_generate_today() / hq_create_from_template() が実タスクの工程
-- （step_id）へその項目をコピーする。
-- ============================================================

create table if not exists hq_step_checklist_items (
  id uuid primary key default gen_random_uuid(),
  step_id uuid references hq_task_steps(id) on delete cascade,
  template_step_id uuid references hq_task_template_steps(id) on delete cascade,
  title text not null,
  sort_order int not null default 100,
  checked_at timestamptz,          -- template_step_id側は常にnull（ひな形のため）
  checked_by uuid references users(id),
  created_at timestamptz not null default now(),
  constraint hq_step_checklist_items_owner_check check (
    (step_id is not null)::int + (template_step_id is not null)::int = 1
  )
);
create index if not exists hq_step_checklist_items_step_idx on hq_step_checklist_items(step_id);
create index if not exists hq_step_checklist_items_tstep_idx on hq_step_checklist_items(template_step_id);

alter table hq_step_checklist_items enable row level security;

-- 閲覧: step_id側はそのタスクが見えるユーザー／template_step_id側はhq_can_manage or TEAM（既存hqlink_read等と同型）
drop policy if exists hqscl_read on hq_step_checklist_items;
create policy hqscl_read on hq_step_checklist_items for select using (
  (step_id is not null and hq_task_visible((select task_id from hq_task_steps where id = step_id)))
  or (template_step_id is not null
      and (hq_can_manage() or exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.role = 'TEAM')))
);

-- テンプレート側ひな形の追加・編集・削除: テンプレ編集と同じくhq_can_manageのみ
drop policy if exists hqscl_tpl_write on hq_step_checklist_items;
create policy hqscl_tpl_write on hq_step_checklist_items for all using (
  template_step_id is not null and hq_can_manage()
) with check (
  template_step_id is not null and hq_can_manage()
);

-- タスク側（チェックのオン/オフ）: その工程に触れる人＝既存hqs_updateの条件と同じ
drop policy if exists hqscl_step_write on hq_step_checklist_items;
create policy hqscl_step_write on hq_step_checklist_items for all using (
  step_id is not null and exists(
    select 1 from hq_task_steps s where s.id = step_id
      and (hq_can_manage() or s.assignee_id = auth.uid() or (s.assignee_id is null and hq_task_visible(s.task_id)))
  )
) with check (
  step_id is not null and exists(
    select 1 from hq_task_steps s where s.id = step_id
      and (hq_can_manage() or s.assignee_id = auth.uid() or (s.assignee_id is null and hq_task_visible(s.task_id)))
  )
);

-- ============================================================
-- hq_generate_today() / hq_create_from_template(): チェックリスト項目のコピーを追加
-- 既存ロジックは一切変更していない（末尾に「テンプレの項目をコピーする」INSERTを
-- 1本追加し、hq_task_steps insertに `returning id into v_new_step_id` を足しただけ）。
-- hq_step_checklist_items が空（未使用）のテンプレでは、追加したINSERTは0件挿入で
-- 終わるだけなので、B7を使わない既存テンプレの動作に影響はない。
-- ============================================================

create or replace function hq_generate_today() returns int
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
    insert into hq_tasks (template_id, title, corp, freq, target_date, due_date, due_time, notes, description, visibility, created_by)
    values (v_tpl.id, v_tpl.title, v_tpl.corp, v_tpl.freq, v_today, v_today + v_tpl.due_offset_days, v_tpl.due_time, v_tpl.notes, v_tpl.description, v_tpl.visibility, v_tpl.created_by)
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
          insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo, store_id)
          values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_today + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_store.id)
          returning id into v_new_step_id;
          insert into hq_step_checklist_items(step_id, title, sort_order)
            select v_new_step_id, ci.title, ci.sort_order
            from hq_step_checklist_items ci where ci.template_step_id = v_step.id order by ci.sort_order;
        end loop;
      else
        insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo)
        values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_today + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo)
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
begin
  if not hq_feature_allowed('newtask') then
    raise exception 'タスクを追加する権限がありません';
  end if;

  select * into v_tpl from hq_task_templates where id = p_template_id;
  if v_tpl is null then
    raise exception 'テンプレートが見つかりません';
  end if;

  insert into hq_tasks (template_id, title, corp, freq, target_date, due_date, due_time, notes, description, visibility, created_by)
  values (v_tpl.id, v_tpl.title, v_tpl.corp, v_tpl.freq, v_date, v_date + v_tpl.due_offset_days, v_tpl.due_time,
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
        insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo, store_id)
        values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_date + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_store.id)
        returning id into v_new_step_id;
        insert into hq_step_checklist_items(step_id, title, sort_order)
          select v_new_step_id, ci.title, ci.sort_order
          from hq_step_checklist_items ci where ci.template_step_id = v_step.id order by ci.sort_order;
      end loop;
    else
      insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo)
      values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_date + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo)
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
