-- ============================================================
-- 2026-11-03 担当B（nippo）— 兼務の人（sf_payroll_syncが人×年月×契約で2行）に備えた、給与タスク・現金手渡しの法人別化
-- 【状態】事前報告（ユーザー確認待ち・未適用）。担当D Phase2（sf_payroll_syncの旧一意制約(user_id,year_month)の削除）の前提
-- 【方針（ユーザー確定 2026-11-03）】給料を支払う会社が違うので、法人が変われば給料振込も現金手渡しも法人ごとに分かれる（合算しない）。
--
-- 【現構造（リポジトリの最新定義＝2026-10-07 担当C版 hq_create_payroll_tasks・2026-09-14版 cash_handoff_targets・2026-09-08版 cash_handoff_complete）】
--   ※本番の定義がリポジトリと一致していることは、適用前に（担当D/Cが）確認してください。違っていれば本番の定義を土台に同じ変更を加える
--   ・cash_handoff_targets は人ごとに1行（sf_payroll_syncを人×年月で結合）。サイン記録 sf_cash_handoff_signatures は unique(user_id,year_month)
--   ・hq_create_payroll_tasks は p_corp を見出しにするだけで、対象者は法人で絞らない（人×年月で結合）
-- 【変更】
--   ① cash_handoff_targets: 「人×契約（支払法人）」ごとに1行。戻り値に contract_id・corp_name を追加（形が変わるので drop→create）。兼務の人は法人が違えば2行・金額も別
--   ② sf_cash_handoff_signatures: contract_id 列を追加（既存の行は既定の契約=トーホー）。一意を (user_id,year_month,contract_id) に変更
--   ③ cash_handoff_complete: 引数 p_contract_id（省略=既定の契約）を追加。給与仕訳の「振込完了」印は、その法人のMF事業者(tenant)の記録だけに付ける
--   ④ hq_create_payroll_tasks: p_corp に対応するスマレジ契約(smaregi_contracts.corporation_id)の給与行だけを対象にする（1法人のタスク内で1人1回）。
--      兼務の人はトーホーのタスクとLiveGateのタスクの両方に出る。p_corp に対応する契約が無い（従来の呼び方）ときは契約で絞らない（互換）
-- 【影響】兼務の人がいない月は結果が変わらない（人ごとに1行・金額も同じ）。兼務の人は法人ごとに別の行・別のサイン。
--   ※nippoの現金手渡し・サイン画面は、このSQLの適用と同時に「法人ごとの行」に対応する版へ更新する（適用前の古い画面は、兼務の人が2行になる11月分
--   （12月に表示）で二重に見えるため、12/1までに画面を更新済みにする）。担当Cの給料確定ボタンは、法人ごとに hq_create_payroll_tasks を呼ぶ必要がある
-- 【migration】本ファイル（冪等）
-- 【rollback】cash_handoff_targets/cash_handoff_complete/hq_create_payroll_tasks を元の定義（2026-09-14・2026-09-08・2026-10-07のSQL）で再作成。
--   列 contract_id と一意制約は、兼務の行が入る前なら戻せる（unique(user_id,year_month)へ戻す）
-- ============================================================

-- ① 現金手渡しの対象者を「人×契約（支払法人）」ごとに1行にする（法人が違えば同じ人が2行・金額も別）。戻り値に contract_id・corp_name を追加
--   （戻り値の形が変わるので drop してから作り直す。呼び出し元は nippo の現金手渡し・サイン画面と hq_create_payroll_tasks）
drop function if exists public.cash_handoff_targets(text);
create or replace function public.cash_handoff_targets(p_year_month text)
 returns table(user_id uuid, name text, store_id uuid, amount numeric, is_active boolean, contract_id text, corp_name text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_caller users%rowtype; v_stores uuid[]; v_scope text; v_def text;
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
  select sc.contract_id into v_def from smaregi_contracts sc where sc.is_default limit 1;

  return query
    select u.id, u.name,
      (select us.store_id from user_stores us where us.user_id = u.id order by us.is_primary desc limit 1),
      coalesce(s.amt, 0),
      u.is_active,
      coalesce(s.contract_id, v_def),
      (select c.name from smaregi_contracts sc2 join corporations c on c.id = sc2.corporation_id where sc2.contract_id = coalesce(s.contract_id, v_def))
    from payroll_bank_accounts pba
    join users u on u.id = pba.user_id
    left join (select sp.user_id, sp.contract_id, sum(sp.net_pay) as amt
                 from sf_payroll_sync sp where sp.year_month = p_year_month group by sp.user_id, sp.contract_id) s on s.user_id = u.id
    where pba.payment_method = 'cash'
      and (v_stores is null or (select us2.store_id from user_stores us2 where us2.user_id = u.id order by us2.is_primary desc limit 1) = any(v_stores));
end;
$function$;
grant execute on function public.cash_handoff_targets(text) to authenticated;

-- ② 受け渡し・サインの記録を「人×月×契約（支払法人）」で1件にする（既存の行はトーホー契約＝既定の契約として扱う）
alter table sf_cash_handoff_signatures add column if not exists contract_id text not null default 'sez093z1';
do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.sf_cash_handoff_signatures'::regclass and contype = 'u'
              and (select array_agg(a.attname order by a.attname) from pg_attribute a where a.attrelid = conrelid and a.attnum = any(conkey)) = array['user_id','year_month']::name[] loop
    execute format('alter table sf_cash_handoff_signatures drop constraint %I', c);
  end loop;
  if not exists (select 1 from pg_constraint where conname = 'sf_cash_handoff_signatures_user_month_contract_key') then
    alter table sf_cash_handoff_signatures add constraint sf_cash_handoff_signatures_user_month_contract_key unique (user_id, year_month, contract_id);
  end if;
end $$;

-- ③ 完了処理: 契約（支払法人）を指定できるようにする（既定=トーホーの既定契約）。給与仕訳の「振込完了」印は、その法人のMF事業者(tenant)の記録だけに付ける
--   （契約→MF事業者: corporation_hint 'toho'→'default'・'livegate'→'livegate'・'nstyle'→'nstyle'・'sk'→'sk'）
drop function if exists public.cash_handoff_complete(uuid, text);
create or replace function public.cash_handoff_complete(p_user_id uuid, p_year_month text, p_contract_id text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_row sf_cash_handoff_signatures%rowtype; v_synced_rows integer := 0; v_contract text; v_tenant text;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (
    is_master or role in ('CEO','HQ','TENCHO','TEAM')
  )) then
    raise exception '権限がありません';
  end if;
  select coalesce(p_contract_id, (select sc.contract_id from smaregi_contracts sc where sc.is_default limit 1)) into v_contract;
  select * into v_row from sf_cash_handoff_signatures where user_id = p_user_id and year_month = p_year_month and contract_id = v_contract;
  if v_row.id is null then
    raise exception '対象の記録が見つかりません';
  end if;
  if v_row.payer_checked_at is null or v_row.receiver_checked_at is null then
    raise exception '渡した側・受け取った側、両方の確認が必要です';
  end if;
  update sf_cash_handoff_signatures set completed_at = now(), updated_at = now()
   where id = v_row.id;
  select case sc.corporation_hint when 'toho' then 'default' else sc.corporation_hint end into v_tenant
    from smaregi_contracts sc where sc.contract_id = v_contract;
  begin
    update payroll_journal_records set paid_at = now(), paid_by = auth.uid()
     where user_id = p_user_id and year_month = p_year_month and paid_at is null
       and (v_tenant is null or tenant_id = v_tenant);
    get diagnostics v_synced_rows = row_count;
  exception when undefined_table then v_synced_rows := 0;
  end;
  return jsonb_build_object('ok', true, 'journal_marked_paid', v_synced_rows > 0);
end;
$function$;
grant execute on function public.cash_handoff_complete(uuid, text, text) to authenticated;

-- ④ 給料確定タスク（法人ごと）
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
  v_contracts text[]; -- 2026-11-03: この法人(p_corp)に対応するスマレジ契約。法人ごとに給与の支払い・手渡しが分かれるため、その法人の給与行だけを対象にする
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

  -- 2026-11-03: 兼務の人は sf_payroll_sync が契約（＝支払法人）ごとに2行になる。給料を支払う会社が違うので、法人ごとにタスクを分ける:
  --   p_corp（法人名）に対応するスマレジ契約(smaregi_contracts.corporation_id→corporations.name)の給与行だけを対象にし、1法人のタスク内で1人1回（exists）。
  --   p_corp に対応する契約が無い法人名（従来の呼び方）のときは、契約で絞らず従来どおり（互換）。
  select array_agg(sc.contract_id) into v_contracts
    from smaregi_contracts sc join corporations c on c.id = sc.corporation_id
   where c.name = p_corp and sc.is_active;
  if v_contracts is not null and array_length(v_contracts, 1) = 0 then v_contracts := null; end if;
  -- 2026-09-17修正: payment_methodを厳密一致にし、対象月のsf_payroll_sync(net_pay>0)があることを必須にした
  select array_agg(u.name order by u.name) into v_transfer_names
    from payroll_bank_accounts pba
    join users u on u.id = pba.user_id
    where pba.payment_method = 'bank_transfer'
      and exists (select 1 from sf_payroll_sync s where s.user_id = u.id and s.year_month = p_year_month and coalesce(s.net_pay, 0) > 0
                    and (v_contracts is null or s.contract_id = any(v_contracts)))
      and not exists (select 1 from sf_payroll_hidden h where h.user_id = u.id and h.year_month = p_year_month);
  select array_agg(t.name order by t.name) into v_cash_names
    from cash_handoff_targets(p_year_month) t where coalesce(t.amount, 0) > 0
      and (v_contracts is null or t.contract_id = any(v_contracts))
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
