-- ============================================================
-- 2026-11-11 担当B — ①既存の給料振込タスク2件の題名を『11月分』→『10月分』に直す（ユーザー指摘）②hq_create_payroll_tasks の既存タスク探しを正しい月に直す
-- 【状態】事前報告（未適用・ユーザーの実行承認待ち）。1ファイル・1トランザクション（先に直してから関数を替える順を固定）
-- 【ユーザー指摘（2026-11-11）】「11月分給料は間違い。10月分給料。今の本部タスクが間違えてる」＝月次テンプレが付けた題名『11月分 【振込トーホー】給料』『11月分 【振込Live】給料』
--   は、実際には【10月分の給与】を11月に払うタスク。題名の月は『給与月』が正しい（給料確定が作るタスクの『10月分　給料振込』や『10月分 【振込Live】源泉所得税』と同じ付け方）
-- 【①データ修正】対象は2件のみ（トーホー・Live）: 題名の『11月分』→『10月分』。期限・工程・進捗はそのまま（トーホー1c87cccd・Live42f148dd）。件数が2でなければ停止
-- 【②関数修正】既存タスク探しの条件を『題名の月＝給与月』『期限＝給与月の翌月1日〜+45日（＝支払う月）』に。→ 10月分の確定は、期限が11月のタスクだけを見る＝期限10月の
--   『10月分（9月分給与）』完了済みタスクにはぶつからない。これで 2026-10 の確定は、直した『10月分』2件に工程を足して紐づく。以前に私が出した『支払月で探す』修正案は取り下げ（作り直し）
-- 【安全ガード】本番の関数が適用済みの版（md5 f47f43e589a226aa030652a6a718c099）か、取り下げた修正案の版（md5 b8f3f2f3145bba55ed8e88138da8d04b）のどちらかでなければ停止
-- 【適用後】2026-10 の給料確定ボタンを、トーホーはもう一度、Liveは初めて押す（Liveの2026-10はまだ未確定）。振込タスクが既存『10月分』に工程を足して紐づき、現金手渡しは二重にならない
-- 【rollback】題名: update hq_tasks set title = replace(title,'10月分','11月分') where id::text like any (array['1c87cccd%','42f148dd%']); 関数: 2026-11-09_payroll_finalized_cash_cancel.sql を再適用
-- ============================================================
do $$
declare n int; r record; v_n int;
begin
  select count(*) into n from pg_proc where proname = 'hq_create_payroll_tasks' and pronamespace = 'public'::regnamespace;
  if n <> 1 then raise exception '停止: hq_create_payroll_tasks が % 本あります（1本のはず）', n; end if;
  select p.prosrc, pg_get_function_identity_arguments(p.oid) as args, p.prosecdef into r from pg_proc p where p.proname = 'hq_create_payroll_tasks' and p.pronamespace = 'public'::regnamespace;
  if r.args <> 'p_year_month text, p_corp text, p_corp_id uuid' or not r.prosecdef then raise exception '停止: 引数/SECURITY DEFINER が想定と違います（%）', r.args; end if;
  if md5(r.prosrc) not in ('f47f43e589a226aa030652a6a718c099', 'b8f3f2f3145bba55ed8e88138da8d04b') then
    raise exception '停止: 本番の本文の指紋が想定と一致しません（本番=%・長さ=%）。何も変更していません', md5(r.prosrc), length(r.prosrc);
  end if;

  -- ①題名の修正（対象2件のみ・未削除・テンプレ由来・題名が想定どおりのものだけ）
  update hq_tasks set title = replace(title, '11月分', '10月分')
   where id::text like any (array['1c87cccd%', '42f148dd%']) and deleted_at is null and template_id is not null
     and title ~ '^11月分[[:space:]　]*【振込(トーホー|Live)】給料$';
  get diagnostics v_n = row_count;
  if v_n <> 2 then raise exception '停止: 題名を直せたタスクが % 件です（想定2件）。何も変更していません', v_n; end if;
end $$;

create or replace function public.hq_create_payroll_tasks(p_year_month text, p_corp text default null, p_corp_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
$function$;

-- ===== 適用後の確認（無害）=====
select left(id::text, 8) as タスク, title as 題名, status as 状態, due_date as 期限 from hq_tasks
 where id::text like any (array['1c87cccd%', '42f148dd%']) order by title;
select count(*) as 本数, bool_and(p.prosecdef) as security_definer,
       bool_or(p.prosrc like '%t.due_date >= v_due_month_start%') as 翌月以降の期限で探す,
       bool_or(p.prosrc like '%extract(month from v_due_month_start)%') as 取り下げた案が残っている
  from pg_proc p where p.proname = 'hq_create_payroll_tasks' and p.pronamespace = 'public'::regnamespace;
select a.grantee::regrole::text as grantee, a.privilege_type
  from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
 where p.proname = 'hq_create_payroll_tasks' and p.pronamespace = 'public'::regnamespace order by 1;
