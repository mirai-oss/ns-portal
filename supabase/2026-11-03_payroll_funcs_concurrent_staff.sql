-- ============================================================
-- 2026-11-03 担当B（nippo）— 兼務の人（sf_payroll_syncが人×年月×契約で2行）に備えた給与タスク・現金手渡し対象の修正
-- 【状態】事前報告（ユーザー確認待ち・未適用）。担当D Phase2（sf_payroll_syncの旧一意制約(user_id,year_month)の削除）の前提
--
-- 【理由】Phase2の適用後は、トーホーとLiveGateの両方に給与がある兼務の人が、同じ年月に2行になる。これらの関数は
--   sf_payroll_sync を「人×年月」で結合しているため、そのままだと兼務の人が二重になる。
-- 【現構造（リポジトリの最新定義＝2026-10-07 担当C版・2026-09-14版）】
--   hq_create_payroll_tasks: 振込の対象者を payroll_bank_accounts × users × sf_payroll_sync の join で集める（同じ名前が2回入る）
--   cash_handoff_targets: 現金手渡しの対象者を payroll_bank_accounts × users × left join sf_payroll_sync で返す（2行返る・金額が分かれる）
--   ※本番の定義がリポジトリと一致していることは、適用前に（担当D/Cが）確認してください。違っていれば、本番の定義を土台に同じ変更を加える
-- 【変更】
--   ① hq_create_payroll_tasks: 振込の対象者の選び方だけを exists（その月に net_pay>0 の給与がある人＝1人1回）に変える。他は同じ
--      （現金は cash_handoff_targets を使うので、②で解決）
--   ② cash_handoff_targets: sf_payroll_sync を user_id ごとに net_pay を合算した副問い合わせに変える（兼務の人は合計額を1回で渡す）。他は同じ
-- 【影響】兼務の人がいない月は結果が変わらない（行は人ごとに1行のまま・金額も同じ）。兼務の人は1人1件・合計額になる。
--   契約（法人）ごとに分けて渡す運用が必要になったら、契約で絞る引数を追加する（今回はしない）
-- 【migration】本ファイル（create or replace・冪等）。【rollback】2026-10-07_hq_create_payroll_tasks_headcount_fix.sql と 2026-09-14_cash_handoff_role_scope.sql の該当関数を再実行
-- ============================================================

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
  -- 2026-11-03: 兼務の人はsf_payroll_syncが契約ごとに2行になるため、joinだと同じ名前が2回入る→existsで「その月に給与がある人」を1人1回だけ数える
  select array_agg(u.name order by u.name) into v_transfer_names
    from payroll_bank_accounts pba
    join users u on u.id = pba.user_id
    where pba.payment_method = 'bank_transfer'
      and exists (select 1 from sf_payroll_sync s where s.user_id = u.id and s.year_month = p_year_month and coalesce(s.net_pay, 0) > 0)
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

create or replace function public.cash_handoff_targets(p_year_month text)
 returns table(user_id uuid, name text, store_id uuid, amount numeric, is_active boolean)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_caller users%rowtype; v_stores uuid[]; v_scope text;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ','TENCHO','TEAM')) then
    raise exception '権限がありません';
  end if;

  if v_caller.is_master then
    v_stores := null; -- masterは設定テーブルに関わらず常に全店舗（安全側の固定）
  else
    select scope into v_scope from cash_handoff_role_scope where role = v_caller.role;
    v_scope := coalesce(v_scope, 'own'); -- 設定が無い役職は最も安全側（自店舗のみ）にフォールバック
    if v_scope = 'all' then
      v_stores := null;
    elsif v_scope = 'team' then
      v_stores := team_store_ids(v_caller.team_id) || user_store_ids(v_caller.id);
    else
      v_stores := user_store_ids(v_caller.id);
    end if;
  end if;

  return query
    select u.id, u.name,
      (select us.store_id from user_stores us where us.user_id = u.id order by us.is_primary desc limit 1),
      coalesce(s.net_pay, 0),
      u.is_active
    from payroll_bank_accounts pba
    join users u on u.id = pba.user_id
    left join (select sp.user_id, sum(sp.net_pay) as net_pay from sf_payroll_sync sp where sp.year_month = p_year_month group by sp.user_id) s on s.user_id = u.id -- 2026-11-03: 兼務の人は契約ごとに2行→人で合算（1回で渡す）
    where pba.payment_method = 'cash'
      and (v_stores is null or (select us2.store_id from user_stores us2 where us2.user_id = u.id order by us2.is_primary desc limit 1) = any(v_stores));
end;
$function$;
