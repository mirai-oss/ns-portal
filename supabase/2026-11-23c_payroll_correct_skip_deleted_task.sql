-- =============================================================
-- 月ごとの支払方法の訂正: 削除済みの本部タスクの名簿には触れない（2026-11-13 実機テストで見つかった点の修正）
--   2026-11-23b の payroll_month_payment_correct は、訂正のときに「その月の名簿（本部タスクのチェック欄）」を合わせるが、
--   対応する本部タスクが削除済み（deleted_at あり）でも、名簿に名前を足していた（実機テストで、テスト従業員の名前が、削除済みの 10 月分の振込タスクに 1 件入った → テストの片づけで削除済み）。
--   直すのは、名簿を探す 2 か所に「削除済みでないタスクだけ」の条件を足すこと。ほかは同じ（本番の定義から生成）。データは変えない。
--   戻し方: 2026-11-23c_payroll_correct_skip_deleted_task_rollback.sql
-- =============================================================
CREATE OR REPLACE FUNCTION public.payroll_month_payment_correct(p_user uuid, p_year_month text, p_method text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare m payroll_month_payments%rowtype; v_old text; v_name text; v_corp uuid; v_new_kind text; v_old_kind text; v_link payroll_task_links%rowtype; v_added boolean := false; v_removed integer := 0; v_sort integer;
begin
  if not public.payroll_pay_can() then raise exception '権限がありません（本部・社長・マスターのみ）'; end if;
  if p_method not in ('bank_transfer', 'cash') then raise exception '支払方法は、銀行振込か現金手渡しを指定してください'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '訂正の理由を入れてください'; end if;
  select * into m from payroll_month_payments where user_id = p_user and year_month = p_year_month for update;
  if not (m.status = 'fixed' or (m.user_id is null and public.payroll_month_is_finalized(p_user, p_year_month))) then
    raise exception '%分はまだ確定していません。確定前の月は、ふつうの変更で直してください', p_year_month;
  end if;
  v_old := public.payroll_month_method(p_user, p_year_month);
  if m.status = 'fixed' and m.method = p_method then return jsonb_build_object('ok', true, 'unchanged', true); end if;

  perform set_config('payroll.month_fix_ok', '1', true);
  insert into payroll_month_payments(user_id, year_month, method, status, account, source, decided_by, fixed_at)
  values (p_user, p_year_month, p_method, 'fixed', case when p_method = 'bank_transfer' then public.payroll_account_snapshot(p_user) end, 'correction', auth.uid(), now())
  on conflict (user_id, year_month) do update
     set method = excluded.method, status = 'fixed', account = excluded.account, source = 'correction', decided_by = auth.uid(), decided_at = now(), fixed_at = coalesce(payroll_month_payments.fixed_at, now()), updated_at = now();
  perform set_config('payroll.month_fix_ok', '', true);
  insert into payroll_month_payment_history(user_id, year_month, kind, before, after, reason, changed_by)
  values (p_user, p_year_month, 'correction', jsonb_build_object('method', v_old, 'status', coalesce(m.status, 'default')), jsonb_build_object('method', p_method, 'status', 'fixed'), left(btrim(p_reason), 500), auth.uid());

  -- 名簿（本部タスクのチェック欄）を合わせる: 新しい側に名前が無ければ足す／古い側の「まだ済みでない」欄だけ外す
  if v_old is distinct from p_method then
    select u.name into v_name from users u where u.id = p_user;
    select sc.corporation_id into v_corp from sf_payroll_sync sp join smaregi_contracts sc on sc.contract_id = sp.contract_id
     where sp.user_id = p_user and sp.year_month = p_year_month order by sp.net_pay desc nulls last limit 1;
    v_new_kind := case when p_method = 'cash' then 'cash' else 'transfer' end; v_old_kind := case when p_method = 'cash' then 'transfer' else 'cash' end;
    select l.* into v_link from payroll_task_links l where l.year_month = p_year_month and l.kind = v_new_kind and l.corporation_id = v_corp
       and exists (select 1 from hq_tasks t where t.id = l.task_id and t.deleted_at is null);   -- 削除済みの本部タスクの名簿には触れない
    if v_link.step_id is not null and v_name is not null
       and not exists (select 1 from hq_step_checklist_items c where c.step_id = v_link.step_id and replace(replace(c.title, ' ', ''), chr(12288), '') = replace(replace(v_name, ' ', ''), chr(12288), '')) then
      select coalesce(max(c.sort_order), 0) + 10 into v_sort from hq_step_checklist_items c where c.step_id = v_link.step_id;
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_link.step_id, v_name, v_sort);
      v_added := true;
    end if;
    select l.* into v_link from payroll_task_links l where l.year_month = p_year_month and l.kind = v_old_kind and l.corporation_id = v_corp
       and exists (select 1 from hq_tasks t where t.id = l.task_id and t.deleted_at is null);   -- 削除済みの本部タスクの名簿には触れない
    if v_link.step_id is not null and v_name is not null then
      delete from hq_step_checklist_items c where c.step_id = v_link.step_id and c.checked_at is null
         and replace(replace(c.title, ' ', ''), chr(12288), '') = replace(replace(v_name, ' ', ''), chr(12288), '');
      get diagnostics v_removed = row_count;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'year_month', p_year_month, 'before', v_old, 'method', p_method, 'task_item_added', v_added, 'task_items_removed', v_removed);
end $function$
;
