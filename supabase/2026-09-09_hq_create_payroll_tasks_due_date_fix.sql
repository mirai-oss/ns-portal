-- 2026-09-09: hq_create_payroll_tasks()の期日計算バグを修正
-- （担当E実機調査・ユーザー報告により判明。WORKLOG 2026-09-09「給料確定ボタンで発行された
-- 本部タスクの法人・期限誤り」参照。担当Cが対応）
--
-- ユーザー報告: 「給料タスクが自動発行されたけど...8月分給料は9月払いなので9月15日の期限に
-- 変更してほしい！」
--
-- 従来はv_month_start（p_year_monthの1日）にそのまま+14/+24日していたため、期日が
-- 「対象月と同じ月」の15日/25日になっていた（8月分→8月15日）。ユーザーの運用（対象月の
-- 給与は翌月払い）に合わせ、期日は対象月の「翌月」の15日/25日にする（8月分→9月15日/25日）。
-- タスクのタイトル・対象月自体（v_mon・"○月分"の表示）は変更しない（対象月の表記は
-- そのまま、期日だけを翌月に）。

create or replace function public.hq_create_payroll_tasks(p_year_month text, p_corp text default 'N-Style'::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_caller users%rowtype;
  v_month_start date; v_due_month_start date; v_mon int;
  v_transfer_due date; v_cash_due date;
  v_transfer_task uuid; v_transfer_step uuid;
  v_cash_task uuid; v_cash_step uuid;
  v_transfer_names text[]; v_cash_names text[];
  v_name text; v_sort int; v_assignees uuid[];
  v_existing payroll_task_links%rowtype;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ')) then
    raise exception '権限がありません（マスター・本部・社長のみ）';
  end if;
  if p_year_month !~ '^\d{4}-\d{2}$' then
    raise exception 'year_monthは YYYY-MM 形式で指定してください';
  end if;
  v_month_start := to_date(p_year_month || '-01', 'YYYY-MM-DD');
  v_mon := extract(month from v_month_start)::int;
  -- 2026-09-09修正: 対象月の給与は翌月払いのため、期日は対象月の「翌月」の15日/25日にする
  v_due_month_start := v_month_start + interval '1 month';
  v_transfer_due := jp_prev_business_day((v_due_month_start + 14)::date); -- 翌月15日
  v_cash_due := jp_prev_business_day((v_due_month_start + 24)::date);     -- 翌月25日

  select array_agg(u.name order by u.name) into v_transfer_names
    from payroll_bank_accounts pba join users u on u.id = pba.user_id
    where pba.payment_method is distinct from 'cash' and u.is_active;
  select array_agg(t.name order by t.name) into v_cash_names
    from cash_handoff_targets(p_year_month) t where t.is_active;

  -- ① 給料振込タスク
  select * into v_existing from payroll_task_links where year_month = p_year_month and kind = 'transfer';
  if v_existing.task_id is not null then
    v_transfer_task := v_existing.task_id;
  elsif v_transfer_names is not null and array_length(v_transfer_names,1) > 0 then
    select coalesce(array_agg(id), array[]::uuid[]) into v_assignees
      from users where is_active and replace(replace(name,' ',''),chr(12288),'') = any(array['青山純','原美香','中山俊士']);
    insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
    values (v_mon||'月分　給料振込　'||p_corp, p_corp, 'once', current_date, v_transfer_due, '',
      '給料確定ボタンにより自動発行（対象'||array_length(v_transfer_names,1)||'名）', 'all', auth.uid())
    returning id into v_transfer_task;
    insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
    values (v_transfer_task, '振込完了を確認', v_assignees, v_transfer_due, 10, 'step')
    returning id into v_transfer_step;
    v_sort := 10;
    foreach v_name in array v_transfer_names loop
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_transfer_step, v_name, v_sort);
      v_sort := v_sort + 10;
    end loop;
    insert into payroll_task_links(year_month, kind, task_id, step_id) values (p_year_month, 'transfer', v_transfer_task, v_transfer_step);
  end if;

  -- ② 現金手渡しタスク
  select * into v_existing from payroll_task_links where year_month = p_year_month and kind = 'cash';
  if v_existing.task_id is not null then
    v_cash_task := v_existing.task_id;
  elsif v_cash_names is not null and array_length(v_cash_names,1) > 0 then
    select coalesce(array_agg(id), array[]::uuid[]) into v_assignees
      from users where is_active and replace(replace(name,' ',''),chr(12288),'') = any(array['青山純','原美香','中山俊士','坂本龍太郎','佐藤俊一','鍋倉巧']);
    insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
    values (v_mon||'月分　現金手渡し　'||p_corp, p_corp, 'once', current_date, v_cash_due, '',
      '給料確定ボタンにより自動発行（対象'||array_length(v_cash_names,1)||'名）', 'all', auth.uid())
    returning id into v_cash_task;
    insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
    values (v_cash_task, '手渡し完了を確認', v_assignees, v_cash_due, 10, 'step')
    returning id into v_cash_step;
    v_sort := 10;
    foreach v_name in array v_cash_names loop
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_cash_step, v_name, v_sort);
      v_sort := v_sort + 10;
    end loop;
    insert into payroll_task_links(year_month, kind, task_id, step_id) values (p_year_month, 'cash', v_cash_task, v_cash_step);
  end if;

  return jsonb_build_object(
    'transfer_task_id', v_transfer_task, 'transfer_due', v_transfer_due, 'transfer_count', coalesce(array_length(v_transfer_names,1),0),
    'cash_task_id', v_cash_task, 'cash_due', v_cash_due, 'cash_count', coalesce(array_length(v_cash_names,1),0)
  );
end;
$function$;
