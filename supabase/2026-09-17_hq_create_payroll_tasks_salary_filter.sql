-- 2026-09-17 担当B（nippo）
-- ユーザー報告「振込タスクの方にも現金手渡しの人が入っていたり、8月分の給料がない人の
-- 名前も入っていたりするので、その月の給料がある人の名前のみ載せてください」に対応。
--
-- 【原因調査】2026-08分の実際のタスクを本番データで確認したところ、以下2つの不具合が
-- 実際に発生していた：
-- ① 振込対象の判定が「payment_method is distinct from 'cash'」だったため、本来は
--    payment_method='bank_transfer'であるべき対象を緩く拾っていた。実データでは現在
--    payment_method='cash'の5名（ジンミョートウ・ソーミントゥッ・チマルシナスリザナ・
--    小川さつき-・松本竜季）が振込チェックリストに、逆にpayment_method='bank_transfer'の
--    1名（YOO WOOSUK）が現金手渡しチェックリストに混在していた（一部は既にチェック済み）。
-- ② 対象月の給与データ（sf_payroll_sync）が存在するかを一切確認しておらず、振込・現金
--    手渡しどちらのリストにも「その月の給与計算がまだ無い人」が含まれていた（実データで
--    10名確認）。
--
-- 【今回の修正】
-- 振込対象: payment_method='bank_transfer'（従来のis distinct fromから厳密一致へ）かつ、
--   sf_payroll_syncにその年月の行があり、net_payが0より大きい人のみに限定。
-- 現金手渡し対象: 既存のcash_handoff_targets(p_year_month)の結果のうち、amount(net_pay)が
--   0より大きい人のみに限定（0円＝その月の給与データが無い/未計算のケースをコード上
--   coalesceで隠していたのを、ここで除外する）。
--
-- 【注意・今回スコープ外】
-- 2026-08分の既存タスクは、上記不具合を含んだ状態で既にチェックリスト項目の一部が
-- チェック済み（実際の運用が進んでいる）。本ファイルは新規作成される「これから」の月の
-- タスクにのみ効く（hq_create_payroll_tasksはpayroll_task_linksで年月×種別ごとに一度
-- 作成したら再生成しない設計のため）。8月分の既存チェックリストをどう是正するかは、
-- 既にチェック済みの項目（給与担当者の実際の確認行動）に影響するため、ユーザーへ内容を
-- 報告した上で個別に対応する（このファイルでは触れない）。
-- また、同姓同名の従業員（例: 松本隼佑が2名）がいる場合、チェックリスト項目が氏名文字列
-- でしか区別されず本人特定が曖昧になる設計上の制約が別途あることも判明したが、これも
-- 今回のスコープ外として別途報告する。

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
    where pba.payment_method = 'bank_transfer' and u.is_active and coalesce(s.net_pay, 0) > 0;
  select array_agg(t.name order by t.name) into v_cash_names
    from cash_handoff_targets(p_year_month) t where t.is_active and coalesce(t.amount, 0) > 0;

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
