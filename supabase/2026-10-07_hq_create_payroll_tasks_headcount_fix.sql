-- 担当C: 給料確定タスクの対象人数を、給与仕訳の画面（KPI）の人数と一致させる
-- 事前報告様式（DB変更）:
-- 理由: ユーザー報告（2026-10-07）「給料確定のタスクで出る人数（振込81・現金32）が、画面の人数（振込80・現金35）と合わない」。
-- 実データで確認した原因（2026-09分）:
--   ① 現金: 画面は35名だが、タスクは在籍（users.is_active）のみで32名。差の3名は退職済み（無効）だが9月分の給与があり
--      既に仕訳登録済み（カウン カン・プエイプエイモーウー・セダイ デイパ）。退職者でも給与が発生していれば手渡し・振込の対象のため、
--      在籍条件は外す。
--   ② 振込: 画面は80名だが、タスクは81名。差の1名（鍋倉 由里子）は給与仕訳の画面で「この月は非表示（対象外）」にしている人だが、
--      タスク側は非表示（sf_payroll_hidden）を見ていなかった。
-- 現構造: hq_create_payroll_tasks(p_year_month, p_corp)（担当B 2026-09-17版）。振込=payment_method='bank_transfer'・在籍・net_pay>0、
--         現金=cash_handoff_targets()の在籍・金額>0。
-- 変更（関数の本文のうち、対象者を選ぶ2つのselectだけ）:
--   振込・現金とも「在籍(is_active)の条件を削除」し「その月の非表示(sf_payroll_hidden)の人を除外」を追加。他の処理・戻り値・権限判定は不変。
-- 既存データへの影響: 関数の書き換えのみ（既存のタスク・チェックリストは変わらない。payroll_task_linksにより同じ年月×種別のタスクは
--   再生成されないため、既に発行済みの2026-09分の人数は修正されない → 別ファイル 2026-10-07_repair_2026-09_payroll_task_lists.sql で是正）。
-- migration: 本ファイル(create or replace・何度流しても壊れない)。 rollback: 2026-09-17_hq_create_payroll_tasks_salary_filter.sql を再実行。

create or replace function public.hq_create_payroll_tasks(p_year_month text, p_corp text default 'N-Style')
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
  v_due_month_start := v_month_start + interval '1 month';
  v_transfer_due := jp_prev_business_day((v_due_month_start + 14)::date); -- 翌月15日
  v_cash_due := jp_prev_business_day((v_due_month_start + 24)::date);     -- 翌月25日

  -- 2026-09-17修正: payment_methodを厳密一致にし、対象月のsf_payroll_sync(net_pay>0)が
  -- あることを必須にした（従来はpayment_methodの判定が緩く、かつ給与データの有無を
  -- 見ていなかったため、支払方法の混在・給与が無い人の混入が起きていた）
  select array_agg(u.name order by u.name) into v_transfer_names
    from payroll_bank_accounts pba
    join users u on u.id = pba.user_id
    join sf_payroll_sync s on s.user_id = u.id and s.year_month = p_year_month
    where pba.payment_method = 'bank_transfer' and coalesce(s.net_pay, 0) > 0
      and not exists (select 1 from sf_payroll_hidden h where h.user_id = u.id and h.year_month = p_year_month);
  select array_agg(t.name order by t.name) into v_cash_names
    from cash_handoff_targets(p_year_month) t where coalesce(t.amount, 0) > 0
      and not exists (select 1 from sf_payroll_hidden h where h.user_id = t.user_id and h.year_month = p_year_month);

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
