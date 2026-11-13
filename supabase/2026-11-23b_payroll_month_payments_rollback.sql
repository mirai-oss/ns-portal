-- 2026-11-23b_payroll_month_payments.sql の戻し: 5 つの関数を元の定義に戻し、足した関数を外す。
--   月ごとの表と履歴の表は、行が無いときだけ消す（行があるときは残す＝記録を消さない。判定は元どおり現在値に戻る）
CREATE OR REPLACE FUNCTION public.cash_handoff_targets_raw(p_year_month text)
 RETURNS TABLE(user_id uuid, name text, store_id uuid, amount numeric, is_active boolean, contract_id text, corp_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_caller users%rowtype; v_stores uuid[]; v_scope text; v_def text;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ','TENCHO','TEAM')) then
    raise exception '権限がありません';
  end if;
  if v_caller.is_master then
    v_stores := null;
  else
    select scope into v_scope from cash_handoff_role_scope where role = v_caller.role;
    v_scope := coalesce(v_scope, 'own');
    if v_scope = 'all' then v_stores := null;
    elsif v_scope = 'team' then v_stores := team_store_ids(v_caller.team_id) || user_store_ids(v_caller.id);
    else v_stores := user_store_ids(v_caller.id);
    end if;
  end if;
  select sc.contract_id into v_def from smaregi_contracts sc where sc.is_default limit 1;
  return query
    select u.id, u.name,
      (select us.store_id from user_stores us where us.user_id = u.id order by us.is_primary desc limit 1),
      coalesce(s.amt, 0), u.is_active, coalesce(s.contract_id, v_def),
      (select c.name from smaregi_contracts sc2 join corporations c on c.id = sc2.corporation_id where sc2.contract_id = coalesce(s.contract_id, v_def))
    from payroll_bank_accounts pba
    join users u on u.id = pba.user_id
    left join (select sp.user_id, sp.contract_id, sum(sp.net_pay) as amt
                 from sf_payroll_sync sp where sp.year_month = p_year_month group by sp.user_id, sp.contract_id) s on s.user_id = u.id
    where pba.payment_method = 'cash'
      and (v_stores is null or (select us2.store_id from user_stores us2 where us2.user_id = u.id order by us2.is_primary desc limit 1) = any(v_stores));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cash_handoff_complete(p_user_id uuid, p_year_month text, p_contract_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row sf_cash_handoff_signatures%rowtype; v_synced_rows integer := 0; v_contract text; v_tenant text;
  v_already_done boolean; v_uname text; v_total int; v_done int; v_corp uuid; v_corp_name text; v_def text; v_chk jsonb;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ','TENCHO','TEAM'))) then
    raise exception '権限がありません';
  end if;
  select sc.contract_id into v_def from smaregi_contracts sc where sc.is_default limit 1;
  v_contract := coalesce(p_contract_id, v_def);
  select * into v_row from sf_cash_handoff_signatures where user_id = p_user_id and year_month = p_year_month and contract_id = v_contract;
  if v_row.id is null then raise exception '対象の記録が見つかりません'; end if;
  if v_row.payer_checked_at is null or v_row.receiver_checked_at is null then
    raise exception '渡した側・受け取った側、両方の確認が必要です';
  end if;

  v_already_done := v_row.completed_at is not null;                                    -- (a) 復元
  update sf_cash_handoff_signatures set completed_at = coalesce(completed_at, now()), updated_at = now() where id = v_row.id;

  select case sc.corporation_hint when 'toho' then 'default' else sc.corporation_hint end, sc.corporation_id, c.name
    into v_tenant, v_corp, v_corp_name
    from smaregi_contracts sc left join corporations c on c.id = sc.corporation_id where sc.contract_id = v_contract;
  begin
    update payroll_journal_records set paid_at = now(), paid_by = auth.uid()
     where user_id = p_user_id and year_month = p_year_month and paid_at is null
       and (v_tenant is null or tenant_id = v_tenant);
    get diagnostics v_synced_rows = row_count;
  exception when undefined_table then v_synced_rows := 0;
  end;

  if not v_already_done then
    begin                                                                              -- (b) 復元: 本部タスクのチェックリスト連携（法人別）
      select name into v_uname from users where id = p_user_id;
      if v_uname is not null then
        v_chk := hq_check_payroll_task_item(p_year_month, 'cash', v_uname, v_corp);
        -- 自動連携が効かなかったときは黙らず通知（本部タスクの手動チェックが必要）
        if not coalesce((v_chk->>'ok')::boolean, false) then
          perform notify_lark('⚠️ 現金手渡し: 本部タスクのチェックを自動で付けられませんでした（'||p_year_month||'・'||coalesce(v_corp_name,'')||'・'||v_uname||'さん）。理由: '||coalesce(v_chk->>'reason','不明')||'。本部タスクを手動で確認してください');
        end if;
      end if;
    exception when others then
      begin perform notify_lark('⚠️ 現金手渡し: 本部タスクの自動チェックでエラーが出ました（'||p_year_month||'・'||coalesce(v_corp_name,'')||'）。本部タスクを手動で確認してください'); exception when others then null; end;
    end;
    begin                                                                              -- (c) 復元: この月×この契約の対象者が全員完了したら通知
      select count(distinct pba.user_id) into v_total
        from payroll_bank_accounts pba join users u on u.id = pba.user_id and u.is_active
       where pba.payment_method = 'cash'
         and (exists (select 1 from sf_payroll_sync sp where sp.user_id = pba.user_id and sp.year_month = p_year_month and sp.contract_id = v_contract)
              or (v_contract = v_def and not exists (select 1 from sf_payroll_sync sp where sp.user_id = pba.user_id and sp.year_month = p_year_month)));
      select count(distinct s.user_id) into v_done
        from sf_cash_handoff_signatures s
        join payroll_bank_accounts pba on pba.user_id = s.user_id and pba.payment_method = 'cash'
        join users u on u.id = s.user_id and u.is_active
       where s.year_month = p_year_month and s.contract_id = v_contract and s.completed_at is not null;
      if v_total > 0 and v_total = v_done then
        perform notify_lark('💴 現金手渡し完了：'||p_year_month||'分（'||coalesce(v_corp_name,'')||'）の現金手渡し対象者 全'||v_total||'名の受け渡しが完了しました（nippo「現金手渡し・サイン」）');
      end if;
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', true, 'journal_marked_paid', v_synced_rows > 0);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cash_handoff_incomplete_alert(p_notify boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_from text := to_char((now() at time zone 'Asia/Tokyo') - interval '2 months', 'YYYY-MM');
  r record; v_total int; v_done int; v_lines text; v_und int; v_all text := ''; v_items jsonb := '[]'::jsonb;
begin
  for r in select f.year_month, f.corporation_id, c.name as corp_name
             from payroll_finalized f join corporations c on c.id = f.corporation_id
            where f.year_month >= v_from
              and v_today >= ((to_date(f.year_month || '-01', 'YYYY-MM-DD') + interval '1 month')::date + 24)   -- 翌月25日以降
            order by f.year_month, c.name loop
    with tg as (
      select u.name,
             (select st.name from user_stores us join stores st on st.id = us.store_id where us.user_id = u.id order by us.is_primary desc limit 1) as store_name,
             rec.payer_checked_at, rec.receiver_checked_at, rec.completed_at, rec.withdrawn_at
        from payroll_bank_accounts pba
        join users u on u.id = pba.user_id
        join (select sp.user_id, sp.contract_id, sum(sp.net_pay) as amt from sf_payroll_sync sp where sp.year_month = r.year_month group by sp.user_id, sp.contract_id) s on s.user_id = u.id
        join smaregi_contracts sc on sc.contract_id = s.contract_id and sc.corporation_id = r.corporation_id
        left join sf_cash_handoff_signatures rec on rec.user_id = u.id and rec.year_month = r.year_month and rec.contract_id = s.contract_id
       where pba.payment_method = 'cash' and coalesce(s.amt, 0) > 0
         and not exists (select 1 from sf_payroll_hidden h where h.user_id = u.id and h.year_month = r.year_month)
    ), und as (
      select '・' || name || coalesce('（' || store_name || '）', '') || '：'
             || case when payer_checked_at is not null and receiver_checked_at is not null then '両者サイン済み・完了処理待ち'
                     when payer_checked_at is not null then '渡した側のみサイン済み（受け取りサイン待ち）'
                     when receiver_checked_at is not null then '受け取った側のみサイン済み（渡した側サイン待ち）'
                     else 'サイン未' end
             || case when withdrawn_at is not null then '／引き出し済み' else '／未引き出し' end as line
        from tg where completed_at is null order by store_name, name limit 30
    )
    select (select count(*) from tg), (select count(*) from tg where completed_at is not null), (select string_agg(line, E'\n') from und)
      into v_total, v_done, v_lines;
    v_und := v_total - v_done;
    if v_total > 0 and v_und > 0 then
      v_all := v_all || E'\n\n■ ' || ltrim(substr(r.year_month, 6), '0') || '月分（' || r.corp_name || '）： 対象' || v_total || '名中 完了' || v_done || '名・未完了' || v_und || '名'
               || E'\n' || coalesce(v_lines, '') || case when v_und > 30 then E'\n…ほか' || (v_und - 30) || '名' else '' end;
      v_items := v_items || jsonb_build_object('year_month', r.year_month, 'corporation', r.corp_name, 'targets', v_total, 'done', v_done, 'undone', v_und);
    end if;
  end loop;
  if v_all <> '' and p_notify then
    perform notify_lark('⚠️ 現金手渡し: 期限（給与月の翌月25日）を過ぎて、サインが完了していない方がいます（完了するまで毎朝お知らせします）' || v_all);
  end if;
  return jsonb_build_object('items', v_items, 'message', nullif(v_all, ''));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.hq_create_payroll_tasks(p_year_month text, p_corp text DEFAULT NULL::text, p_corp_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_caller users%rowtype;
  v_month_start date; v_due_month_start date; v_mon int;
  v_transfer_due date; v_cash_due date;
  v_transfer_task uuid; v_transfer_step uuid; v_cash_task uuid; v_cash_step uuid;
  v_transfer_names text[]; v_cash_names text[];
  v_name text; v_sort int; v_assignees uuid[];
  v_existing payroll_task_links%rowtype;
  v_contracts text[]; v_corp_id uuid;
  v_tpl uuid[]; v_ttask hq_tasks%rowtype; v_attached boolean := false; v_warn text := '';
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ')) then
    raise exception '権限がありません（マスター・本部・社長のみ）';
  end if;
  if p_year_month !~ '^\d{4}-\d{2}$' then raise exception 'year_monthは YYYY-MM 形式で指定してください'; end if;
  v_month_start := to_date(p_year_month || '-01', 'YYYY-MM-DD');
  v_mon := extract(month from v_month_start)::int;
  v_due_month_start := v_month_start + interval '1 month';
  v_transfer_due := jp_prev_business_day((v_due_month_start + 14)::date);
  v_cash_due := jp_prev_business_day((v_due_month_start + 24)::date);

  -- 法人の決め方（担当C確認: ボタンが渡す名前は corporations.name と完全一致）:
  --   ① p_corp_id（法人ID）があればそれを優先（実在しなければエラー） ② 無ければ p_corp（名前）→ID。名前が無い呼び出し（引数なし）だけ従来の既定 'N-Style'
  --   ID も名前も解決できないときは既定へ落とさずエラーで止める（別法人の確定をトーホー等として記録する事故を防ぐ）
  if p_corp_id is not null then
    select c.id, c.name into v_corp_id, p_corp from corporations c where c.id = p_corp_id;
    if v_corp_id is null then raise exception '法人IDが見つかりません'; end if;
  else
    p_corp := coalesce(p_corp, 'N-Style');
    select c.id into v_corp_id from corporations c where c.name = p_corp limit 1;
    if v_corp_id is null then raise exception '法人名「%」が見つかりません（corporations.name と一致する名前、または法人IDを指定してください）', p_corp; end if;
  end if;
  select array_agg(sc.contract_id) into v_contracts from smaregi_contracts sc where sc.corporation_id = v_corp_id and sc.is_active;
  if v_contracts is not null and array_length(v_contracts, 1) = 0 then v_contracts := null; end if;

  -- 確定の印（月×法人）。以降、現金手渡し画面にこの法人の対象者が出る
  insert into payroll_finalized(year_month, corporation_id, finalized_by) values (p_year_month, v_corp_id, auth.uid())
  on conflict (year_month, corporation_id) do nothing;

  select array_agg(u.name order by u.name) into v_transfer_names
    from payroll_bank_accounts pba join users u on u.id = pba.user_id
    where pba.payment_method = 'bank_transfer'
      and exists (select 1 from sf_payroll_sync s where s.user_id = u.id and s.year_month = p_year_month and coalesce(s.net_pay, 0) > 0
                    and (v_contracts is null or s.contract_id = any(v_contracts)))
      and not exists (select 1 from sf_payroll_hidden h where h.user_id = u.id and h.year_month = p_year_month);
  select array_agg(t.name order by t.name) into v_cash_names
    from cash_handoff_targets_raw(p_year_month) t where coalesce(t.amount, 0) > 0
      and (v_contracts is null or t.contract_id = any(v_contracts))
      and not exists (select 1 from sf_payroll_hidden h where h.user_id = t.user_id and h.year_month = p_year_month);

  select * into v_existing from payroll_task_links where year_month = p_year_month and kind = 'transfer' and corporation_id = v_corp_id;
  if v_existing.task_id is not null then
    v_transfer_task := v_existing.task_id;
  elsif v_transfer_names is not null and array_length(v_transfer_names,1) > 0 then
    select coalesce(array_agg(id), array[]::uuid[]) into v_assignees
      from users where is_active and replace(replace(name,' ',''),chr(12288),'') = any(array['青山純','原美香','中山俊士']);
    -- 月次テンプレ由来の既存「【振込◯◯】給料」タスク（題名の月＝給与月・期限は給与月の翌月以降・同じ法人・未削除。※過去分の誤った題名『支払月』は先に給与月へ直してから使う）があれば新規に作らず、そこに確認工程を足して紐づける（二重防止・U-25①）
    select array_agg(t.id) into v_tpl from hq_tasks t
     where t.corp = p_corp and t.template_id is not null and t.deleted_at is null
       and t.title ~ ('^'||v_mon||'月分[[:space:]　]*【振込[^】]*】給料$') and t.title not like '%口振%'
       and t.due_date >= v_due_month_start and t.due_date <= (v_due_month_start + 45);
    if v_tpl is not null and array_length(v_tpl,1) > 1 then
      v_warn := v_warn || '既存の振込タスクが'||array_length(v_tpl,1)||'件見つかったため、自動では紐づけず新規作成もしていません。本部で整理してください。';
    elsif v_tpl is not null then
      select * into v_ttask from hq_tasks where id = v_tpl[1];
      if v_ttask.status = 'done' then
        v_warn := v_warn || '既存の振込タスクが完了済みのため、紐づけも新規作成もしていません。';
      else
        v_transfer_task := v_ttask.id;
        insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
        values (v_transfer_task, '振込対象者の確認（給料確定リスト）', v_assignees, v_ttask.due_date,
                (select coalesce(max(sort_order),0) + 10 from hq_task_steps where task_id = v_transfer_task), 'step')
        returning id into v_transfer_step;
        v_sort := 10;
        foreach v_name in array v_transfer_names loop
          insert into hq_step_checklist_items(step_id, title, sort_order) values (v_transfer_step, v_name, v_sort);
          v_sort := v_sort + 10;
        end loop;
        insert into payroll_task_links(year_month, kind, task_id, step_id, corporation_id) values (p_year_month, 'transfer', v_transfer_task, v_transfer_step, v_corp_id);
        v_attached := true;
      end if;
    else
      insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
      values (v_mon||'月分　給料振込　'||p_corp, p_corp, 'once', current_date, v_transfer_due, '',
        '給料確定ボタンにより自動発行（対象'||array_length(v_transfer_names,1)||'名）', 'all', auth.uid())
      returning id into v_transfer_task;
      insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
      values (v_transfer_task, '振込完了を確認', v_assignees, v_transfer_due, 10, 'step') returning id into v_transfer_step;
      v_sort := 10;
      foreach v_name in array v_transfer_names loop
        insert into hq_step_checklist_items(step_id, title, sort_order) values (v_transfer_step, v_name, v_sort);
        v_sort := v_sort + 10;
      end loop;
      insert into payroll_task_links(year_month, kind, task_id, step_id, corporation_id) values (p_year_month, 'transfer', v_transfer_task, v_transfer_step, v_corp_id);
    end if;
  end if;

  select * into v_existing from payroll_task_links where year_month = p_year_month and kind = 'cash' and corporation_id = v_corp_id;
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
    values (v_cash_task, '手渡し完了を確認', v_assignees, v_cash_due, 10, 'step') returning id into v_cash_step;
    v_sort := 10;
    foreach v_name in array v_cash_names loop
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_cash_step, v_name, v_sort);
      v_sort := v_sort + 10;
    end loop;
    insert into payroll_task_links(year_month, kind, task_id, step_id, corporation_id) values (p_year_month, 'cash', v_cash_task, v_cash_step, v_corp_id);
  end if;

  -- 確定の結果を通知。0名・紐づけ失敗などは ⚠️ を付けて知らせる（黙って終わらせない）
  if coalesce(array_length(v_transfer_names,1),0) = 0 and coalesce(array_length(v_cash_names,1),0) = 0 then
    v_warn := v_warn || '振込・現金とも対象者が0名でした。給与データの取り込み漏れがないか確認してください。';
  end if;
  begin
    perform notify_lark('💰 給料確定: '||p_year_month||'（'||p_corp||'） 振込'||coalesce(array_length(v_transfer_names,1),0)||'名・現金'||coalesce(array_length(v_cash_names,1),0)||'名'
      ||case when v_attached then '（既存の振込タスクに確認工程を追加）' else '' end
      ||case when v_warn <> '' then E'\n⚠️ '||v_warn else '' end);
  exception when others then null;
  end;

  return jsonb_build_object(
    'corporation_id', v_corp_id, 'transfer_attached', v_attached, 'warning', nullif(v_warn, ''),
    'transfer_task_id', v_transfer_task, 'transfer_due', v_transfer_due, 'transfer_count', coalesce(array_length(v_transfer_names,1),0),
    'cash_task_id', v_cash_task, 'cash_due', v_cash_due, 'cash_count', coalesce(array_length(v_cash_names,1),0)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pay_transfer_pending_holds(p_year_month text)
 RETURNS TABLE(user_id uuid, request_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select q.user_id, q.id from profile_change_requests q
   where q.field = 'bank_account' and q.status = 'pending' and (q.effective_year_month is null or q.effective_year_month <= p_year_month)
     -- いま銀行振込の口座が登録されている人だけ（口座が未登録・現金手渡しの人は、もともと振込データに入らない＝従来どおりの扱い）
     and exists (select 1 from payroll_bank_accounts b where b.user_id = q.user_id and coalesce(b.payment_method, 'bank_transfer') <> 'cash')
     and not exists (select 1 from payroll_transfer_schedule t where t.year_month = p_year_month
                      and t.created_at < coalesce((select (value ->> 'transfer_guard_since')::timestamptz from app_settings where key = 'employee_change'), '-infinity'::timestamptz))
     and not exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = p_year_month and s.user_id = q.user_id)
  union all
  -- 2026-11-12 開発 2: 未承認の賃金変更がある人（関所が有効のときだけ。口座変更で既に外す人は重ねない）
  select w.user_id, null::uuid from payroll_wage_holds(p_year_month) w
   where exists (select 1 from payroll_bank_accounts b where b.user_id = w.user_id and coalesce(b.payment_method, 'bank_transfer') <> 'cash')
     and not exists (select 1 from payroll_transfer_schedule t where t.year_month = p_year_month
                      and t.created_at < coalesce((select (value ->> 'transfer_guard_since')::timestamptz from app_settings where key = 'employee_change'), '-infinity'::timestamptz))
     and not exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = p_year_month and s.user_id = w.user_id)
     and not exists (select 1 from profile_change_requests q2 where q2.user_id = w.user_id and q2.field = 'bank_account' and q2.status = 'pending' and (q2.effective_year_month is null or q2.effective_year_month <= p_year_month))
$function$
;

drop function if exists public.payroll_month_payments_backfill(boolean);
drop function if exists public.payroll_month_methods(text);
drop function if exists public.payroll_month_payment_status(uuid, integer);
drop function if exists public.payroll_month_payment_correct(uuid, text, text, text);
drop function if exists public.payroll_payment_change(uuid, text, text, boolean, text);
drop function if exists public.payroll_month_payments_fix(text, text[]);
drop function if exists public.payroll_account_snapshot(uuid);
drop function if exists public.payroll_pay_can();
drop function if exists public.payroll_month_is_finalized(uuid, text);
drop function if exists public.payroll_month_method(uuid, text);
do $$ begin
  if to_regclass('public.payroll_month_payments') is not null and not exists (select 1 from public.payroll_month_payments) then
    drop trigger if exists payroll_month_payments_guard on public.payroll_month_payments;
    drop table public.payroll_month_payments;
    drop function if exists public.payroll_month_payments_guard();
  end if;
  if to_regclass('public.payroll_month_payment_history') is not null and not exists (select 1 from public.payroll_month_payment_history) then drop table public.payroll_month_payment_history; end if;
end $$;
