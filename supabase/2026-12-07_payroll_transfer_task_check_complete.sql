-- 本部タスク「給与振込確認」: 名簿が全員チェック済みになったら、タスクも完了にする（2026-11-15・社長の指示）
--   2026-12-06_payroll_transfer_task_check.sql の関数 payroll_transfer_task_check に、完了の処理を足したもの（ほかの行は同じ）。
--   ・完了にするのは、名簿の全員にチェックがあるときだけ（照合が入れたチェックと、人が入れたチェックの合計）。
--   ・工程の完了は、既存の見張り（payroll_transfer_confirm_step_guard）と、タスクの状態の計算（hq_task_recalc_status）を通る。
--   ・初めて完了になったときだけ、既存の完了の知らせ（notify_lark → Slack の本部の監視チャンネル。金額・口座は入らない）を出す。
-- 戻し方: 2026-12-06_payroll_transfer_task_check.sql の同じ関数を流し直す。

create or replace function public.payroll_transfer_task_check(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_uid uuid := auth.uid(); v_b payroll_transfer_batches%rowtype; v_task uuid; v_step uuid; v_tasks integer;
  v_l record; v_name text; v_same integer; v_items integer; v_item hq_step_checklist_items%rowtype; v_by uuid; v_at timestamptz;
  v_checked integer := 0; v_already integer := 0; v_no_item integer := 0; v_ambiguous integer := 0; v_not_final integer := 0; v_before integer := 0;
  v_total integer; v_done integer; v_title text; v_was_done boolean; v_completed boolean := false;
begin
  if v_uid is null or public.payroll_pay_can() is not true then raise exception '権限がありません（給与の担当者としてログインしてください）'; end if;
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;

  -- 振込予定日が同じ「給与振込確認」のタスク（削除していないもの）。ちょうど 1 つのときだけ進む
  select count(*) into v_tasks
    from transfer_confirm_task_links k join hq_tasks t on t.id = k.hq_task_id
   where k.kind = 'payroll' and t.deleted_at is null and t.due_date = v_b.scheduled_date and t.title like '給与振込確認%';
  if v_tasks <> 1 then
    return jsonb_build_object('ok', false, 'reason', case when v_tasks = 0 then 'no_task' else 'multiple_tasks' end,
                              'message', case when v_tasks = 0 then '振込予定日が同じ「給与振込確認」のタスクがありません' else '振込予定日が同じ「給与振込確認」のタスクが 2 つ以上あります' end);
  end if;
  select t.id into v_task
    from transfer_confirm_task_links k join hq_tasks t on t.id = k.hq_task_id
   where k.kind = 'payroll' and t.deleted_at is null and t.due_date = v_b.scheduled_date and t.title like '給与振込確認%';
  select s.id into v_step from hq_task_steps s where s.task_id = v_task and s.sort_order = 10;
  if v_step is null then return jsonb_build_object('ok', false, 'reason', 'no_step', 'message', 'タスクに「振込先を確認」の工程がありません'); end if;
  perform pg_advisory_xact_lock(hashtext('payroll_transfer_task_check:' || p_batch_id::text));

  for v_l in select l.id, l.user_id, l.line_status from payroll_transfer_batch_lines l where l.batch_id = p_batch_id order by l.user_id loop
    if v_l.line_status not in ('completed', 'manual_confirmed') then v_not_final := v_not_final + 1; continue; end if;
    if exists (select 1 from payroll_transfer_task_checks c where c.line_id = v_l.id and c.cleared_at is null) then v_before := v_before + 1; continue; end if;
    select replace(replace(u.name, ' ', ''), chr(12288), '') into v_name from users u where u.id = v_l.user_id;
    if coalesce(v_name, '') = '' then v_no_item := v_no_item + 1; continue; end if;
    -- 同じ名前の人が、このバッチに 2 人以上いたら触らない
    select count(*) into v_same from payroll_transfer_batch_lines l2 join users u2 on u2.id = l2.user_id
     where l2.batch_id = p_batch_id and replace(replace(u2.name, ' ', ''), chr(12288), '') = v_name;
    select count(*) into v_items from hq_step_checklist_items i where i.step_id = v_step and replace(replace(i.title, ' ', ''), chr(12288), '') = v_name;
    if v_items = 0 then v_no_item := v_no_item + 1; continue; end if;
    if v_same > 1 or v_items > 1 then v_ambiguous := v_ambiguous + 1; continue; end if;
    select * into v_item from hq_step_checklist_items i where i.step_id = v_step and replace(replace(i.title, ' ', ''), chr(12288), '') = v_name for update;
    if v_item.checked_at is not null then v_already := v_already + 1; continue; end if;
    select c.confirmed_by into v_by from payroll_transfer_manual_confirmations c where c.line_id = v_l.id and c.action = 'confirm' order by c.confirmed_at desc limit 1;
    v_by := coalesce(v_by, v_uid); v_at := now();
    update hq_step_checklist_items i set checked_at = v_at, checked_by = v_by where i.id = v_item.id and i.checked_at is null;
    insert into payroll_transfer_task_checks(line_id, batch_id, item_id, task_id, checked_at_set, checked_by_set, marked_by)
    values (v_l.id, p_batch_id, v_item.id, v_task, v_at, v_by, v_uid)
    on conflict (line_id) do update set item_id = excluded.item_id, task_id = excluded.task_id, checked_at_set = excluded.checked_at_set,
      checked_by_set = excluded.checked_by_set, marked_by = excluded.marked_by, marked_at = now(), cleared_at = null;
    v_checked := v_checked + 1;
  end loop;
  if v_checked > 0 then
    insert into hq_task_activity(task_id, actor_id, kind, detail)
    values (v_task, v_uid, 'comment', '振込照合で確認済みの ' || v_checked || ' 名に、チェックを入れました（銀行の振込結果と照合した人だけ）');
  end if;
  -- 2026-11-15 追加: 名簿が全員チェック済みになったら、工程「振込先を確認」を完了にする（タスクの状態は、既存の仕組みが工程から計算する）。
  --   給料確定のタスクの名簿（hq_check_payroll_task_item）と同じやり方: 工程の完了の日時と人を入れ、初めて完了になったときだけ、完了の知らせを出す。
  --   1 人でもチェックが無ければ、完了にしない。
  select count(*), count(*) filter (where i.checked_at is not null) into v_total, v_done from hq_step_checklist_items i where i.step_id = v_step;
  if v_total > 0 and v_total = v_done then
    select t.title, (t.status = 'done') into v_title, v_was_done from hq_tasks t where t.id = v_task;
    update hq_task_steps s set completed_at = coalesce(s.completed_at, now()), completed_by = coalesce(s.completed_by, v_uid) where s.id = v_step;
    v_completed := true;
    if v_was_done is not true then
      perform notify_lark('✅ ' || v_title || ' が完了しました（全' || v_total || '件チェック済み）');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'checked', v_checked, 'already_checked', v_already, 'checked_before', v_before, 'no_item', v_no_item,
                            'ambiguous', v_ambiguous, 'not_final', v_not_final,
                            'step_completed', v_completed, 'task_status', (select t.status from hq_tasks t where t.id = v_task),
                            'items_total', (select count(*) from hq_step_checklist_items i where i.step_id = v_step),
                            'items_checked', (select count(*) from hq_step_checklist_items i where i.step_id = v_step and i.checked_at is not null));
end $$;
revoke all on function public.payroll_transfer_task_check(uuid) from public, anon;
grant execute on function public.payroll_transfer_task_check(uuid) to authenticated, service_role;
