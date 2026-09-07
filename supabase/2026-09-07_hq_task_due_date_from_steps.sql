-- 2026-09-07（担当E）本部タスクの「全体期限」が最終工程の期限とずれる不具合を修正
--
-- ユーザー報告: 「9月分【振込N-Style】GOSSO他」で全体期限が9/1のまま、最終工程「確認」の
-- 期限は9/20になっていた。
--
-- 原因: hq_generate_today()/hq_create_from_template()（テンプレから毎日/毎回タスクを
-- 自動生成する関数）は、タスクの全体期限をテンプレート自身のdue_offset_days（工程とは
-- 別に手入力する「対象日から何日後か」欄）だけで決めており、実際に生成する各工程の
-- offset_daysとは一切連動していなかった。テンプレート編集画面はこの2つが別々の入力欄に
-- なっており、工程の期限だけ変えてテンプレート自体の期限を直し忘れる、という食い違いが
-- 起きやすい作りだった。実際に調べたところ本部タスクのテンプレート41件中で
-- due_offset_days < 工程の最大offset_days という食い違いが見つかった（GOSSO以外にも多数）。
--
-- 方針: 「タスクの全体期限は、どの工程よりも早くなってはいけない」という不変条件を
-- 生成時に保証する。due_offset_daysの方が大きい場合（あえて工程完了後にも猶予期間を
-- 持たせているテンプレートが実在した＝家賃・SK請求書一式など）はそちらを尊重し、
-- 工程のoffset_daysの方が大きい場合（今回のバグの典型パターン）はそちらに合わせる
-- ＝ GREATEST(テンプレのdue_offset_days, 工程の最大offset_days) を採用。

-- ①今後の自動生成が正しくなるよう、生成関数2つを修正
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
  v_max_offset int;
  v_max_due_time time;
  v_due_date date;
  v_due_time time;
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

    select ts.offset_days, ts.due_time into v_max_offset, v_max_due_time
      from hq_task_template_steps ts where ts.template_id = v_tpl.id
      order by ts.offset_days desc, coalesce(ts.due_time,'23:59'::time) desc limit 1;
    v_due_date := v_today + greatest(v_tpl.due_offset_days, coalesce(v_max_offset,0));
    v_due_time := case when coalesce(v_max_offset,0) > v_tpl.due_offset_days then v_max_due_time else v_tpl.due_time end;

    insert into hq_tasks (template_id, title, corp, freq, target_date, due_date, due_time, notes, description, visibility, created_by)
    values (v_tpl.id, v_title, v_tpl.corp, v_tpl.freq, v_today, v_due_date, v_due_time, v_tpl.notes, v_tpl.description, v_tpl.visibility, v_tpl.created_by)
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

-- ②テンプレートから手動で1件作る方（「📋テンプレートに登録」画面の「今すぐ1件作る」等）も同様に修正
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
  v_max_offset int;
  v_max_due_time time;
  v_due_date date;
  v_due_time time;
begin
  if not hq_feature_allowed('newtask') then
    raise exception 'タスクを追加する権限がありません';
  end if;

  select * into v_tpl from hq_task_templates where id = p_template_id;
  if v_tpl is null then
    raise exception 'テンプレートが見つかりません';
  end if;

  v_title := case when v_tpl.freq = 'monthly' then (extract(month from v_date)::int || '月分 ' || v_tpl.title) else v_tpl.title end;

  select ts.offset_days, ts.due_time into v_max_offset, v_max_due_time
    from hq_task_template_steps ts where ts.template_id = v_tpl.id
    order by ts.offset_days desc, coalesce(ts.due_time,'23:59'::time) desc limit 1;
  v_due_date := v_date + greatest(v_tpl.due_offset_days, coalesce(v_max_offset,0));
  v_due_time := case when coalesce(v_max_offset,0) > v_tpl.due_offset_days then v_max_due_time else v_tpl.due_time end;

  insert into hq_tasks (template_id, title, corp, freq, target_date, due_date, due_time, notes, description, visibility, created_by)
  values (v_tpl.id, v_title, v_tpl.corp, v_tpl.freq, v_date, v_due_date, v_due_time,
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

-- ③既存データのバックフィル（今後の生成だけ直しても、既に作られてしまっている
--   タスク・テンプレートの数字は直らないため）

-- ③-1: テンプレート自体のdue_offset_daysを「GREATEST(現在値, 工程の最大offset_days)」に是正
--   （調査の結果、本部タスクのテンプレート41件でこの食い違いが見つかった。工程の期限だけ
--   直して、テンプレート自体の「対象日から何日後か」を直し忘れるケースが多かったとみられる）
with maxoff as (
  select template_id, max(offset_days) as max_offset from hq_task_template_steps group by template_id
)
update hq_task_templates t
set due_offset_days = greatest(t.due_offset_days, m.max_offset)
from maxoff m
where m.template_id = t.id
  and t.due_offset_days < m.max_offset;

-- ③-2: 現在「未完了」の本部タスクのうち、全体期限が工程の最大期限より前になっているものを是正
--   （完了済みタスクの過去の記録は触らない）
with maxstep as (
  select task_id, max(due_date) as max_due,
         (array_agg(due_time order by due_date desc nulls last, coalesce(due_time,'23:59'::time) desc))[1] as max_due_time
  from hq_task_steps where due_date is not null group by task_id
)
update hq_tasks t
set due_date = m.max_due,
    due_time = case when m.max_due > t.due_date then m.max_due_time else t.due_time end
from maxstep m
where m.task_id = t.id
  and t.deleted_at is null
  and t.status <> 'done'
  and t.due_date < m.max_due;
