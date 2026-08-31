-- ============================================================
-- 本部タスク: 毎月テンプレートから自動発行されるタスクのタイトル先頭に「◯月分」を付ける
-- 作成: 2026-08-31 ／ 担当E（本部タスクボード）
--
-- ユーザー要望: 「毎月の項目は、自動発行の時にその月分とわかるようにタイトルの最初に
-- ○月分、と表示されるとかしてほしい（他の方法でも問題なし）」
--
-- 対応: hq_generate_today()（毎朝の自動生成）とhq_create_from_template()（テンプレートから
-- 手動で今すぐ1件作る機能）の両方で、テンプレートのfreqが'monthly'のときだけ、
-- タイトルの先頭に対象日の月を使って「N月分 」を付けてから保存する。daily/weekly/onceは
-- 変更しない（ユーザーが「毎月の項目」と明示したため）。
--
-- 既存のロジック（誰にいつ何を作るか・工程/チェックリストのコピー等）は一切変えず、
-- タイトル文字列の組み立て部分だけを変更する。過去に自動生成済みのタスクは対象外
-- （さかのぼってのリネームはしない。今後の自動生成分から反映される）。
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
          insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo, store_id, procedure_note)
          values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_today + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_store.id, v_step.procedure_note)
          returning id into v_new_step_id;
          insert into hq_step_checklist_items(step_id, title, sort_order)
            select v_new_step_id, ci.title, ci.sort_order
            from hq_step_checklist_items ci where ci.template_step_id = v_step.id order by ci.sort_order;
        end loop;
      else
        insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo, procedure_note)
        values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_today + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_step.procedure_note)
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
        insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo, store_id, procedure_note)
        values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_date + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_store.id, v_step.procedure_note)
        returning id into v_new_step_id;
        insert into hq_step_checklist_items(step_id, title, sort_order)
          select v_new_step_id, ci.title, ci.sort_order
          from hq_step_checklist_items ci where ci.template_step_id = v_step.id order by ci.sort_order;
      end loop;
    else
      insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo, procedure_note)
      values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_date + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_step.procedure_note)
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
