-- ============================================================
-- 全面刷新Phase3: 工程の「手順書」（読み物としての手順テキスト）をチェックリストと分離
-- 作成: 2026-08-26 ／ 担当E（本部タスクボード改善）
--
-- ユーザー指摘: デザイン案では「✅チェック」（チェックボックスで完了管理する項目）と
-- 「📘手順書」（箇条書きの説明テキスト。チェックはしない読み物）が別セクションなのに、
-- 現行実装ではチェックリストしか無く2つが混同されている。
--
-- 新規列のみ追加（既存ルールどおり）。hq_task_template_steps.procedure_note を
-- ひな形として持ち、hq_generate_today()/hq_create_from_template()経由で
-- hq_task_steps.procedure_note へそのままコピーする（チェックリストと同じ方式）。
-- 複数行テキストをアプリ側で改行分割し、番号付きリストとして表示する想定。
-- ============================================================

alter table hq_task_template_steps add column if not exists procedure_note text;
alter table hq_task_steps add column if not exists procedure_note text;

-- ============================================================
-- hq_generate_today() / hq_create_from_template(): procedure_noteのコピーを追加
-- 既存ロジックは変更せず、hq_task_steps insert文にprocedure_noteを1列追加しただけ。
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
