-- 振込照合が「自動で完了」したとき、給与の「振込済」と本部タスクのチェックまで自動で反映する（2026-12-08・引継ぎ書 5）
--   ・新スイッチ app_settings.payroll_transfer_recon.auto_reflect（既定 false）。true かつ auto_complete で自動完了したときだけ動く。手動確認の完了（kind=manual）には連鎖しない。
--   ・payroll_transfer_paid_backfill / payroll_transfer_task_check: 本番の関数をそのまま取り、権限の 1 行だけ「service_role でも通す」に変えた（ほかは無変更）。
--   ・payroll_recon_complete: 本番の関数をそのまま取り、完了のあとに「反映」を足しただけ。反映が失敗しても完了は巻き戻さない（失敗は照合の記録に残す）。
--   ・反映のルールは今までどおり: 完了／手動確認の行だけ・仕訳が 1 行に決まる人だけ・すでに印がある行は触らない・照合が入れた印だけを記録。
--   ・本部タスクの完了の知らせ（notify_lark）は、既存どおり初めて完了になったときだけ出る。
-- 戻し方: 2026-12-08_payroll_transfer_auto_reflect_rollback.sql
update app_settings set value = jsonb_set(value, '{auto_reflect}', 'false'::jsonb, true) where key = 'payroll_transfer_recon' and not (value ? 'auto_reflect');

CREATE OR REPLACE FUNCTION public.payroll_transfer_paid_backfill(p_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  v_uid uuid := auth.uid(); v_b payroll_transfer_batches%rowtype; v_l record; v_n integer; v_j payroll_journal_records%rowtype;
  v_at timestamptz; v_by uuid;
  v_marked integer := 0; v_already integer := 0; v_no_journal integer := 0; v_multi integer := 0; v_done_before integer := 0; v_not_final integer := 0;
begin
  if not (public.payroll_recon_is_service() or (v_uid is not null and public.payroll_pay_can() is true)) then raise exception '権限がありません（給与の担当者としてログインしてください）'; end if;   -- 2026-12-08: 自動の反映（service_role）も通す
  select * into v_b from payroll_transfer_batches b where b.id = p_batch_id;
  if v_b.id is null then raise exception 'バッチが見つかりません'; end if;
  perform pg_advisory_xact_lock(hashtext('payroll_transfer_paid_backfill:' || p_batch_id::text));

  for v_l in select l.id, l.user_id, l.year_month, l.line_status from payroll_transfer_batch_lines l where l.batch_id = p_batch_id order by l.user_id loop
    if v_l.line_status not in ('completed', 'manual_confirmed') then v_not_final := v_not_final + 1; continue; end if;   -- 完了でない行は触らない
    if exists (select 1 from payroll_transfer_paid_marks m where m.line_id = v_l.id and m.cleared_at is null) then v_done_before := v_done_before + 1; continue; end if;
    select count(*) into v_n from payroll_journal_records j where j.user_id = v_l.user_id and j.year_month = v_l.year_month;
    if v_n = 0 then v_no_journal := v_no_journal + 1; continue; end if;       -- 仕訳の行が無い人は触らない
    if v_n > 1 then v_multi := v_multi + 1; continue; end if;                 -- その月に仕訳の行が 2 つ以上ある人は、どれか決められないので触らない
    select * into v_j from payroll_journal_records j where j.user_id = v_l.user_id and j.year_month = v_l.year_month for update;
    if v_j.paid_at is not null then v_already := v_already + 1; continue; end if;   -- すでに印がある行は触らない
    -- 印の日時と人: 手動確認ならその確認の日時と確認者。そうでなければ、バッチの完了の日時
    select c.confirmed_at, c.confirmed_by into v_at, v_by
      from payroll_transfer_manual_confirmations c where c.line_id = v_l.id and c.action = 'confirm' order by c.confirmed_at desc limit 1;
    v_at := coalesce(v_at, v_b.completed_at, now());
    update payroll_journal_records j set paid_at = v_at, paid_by = v_by where j.id = v_j.id and j.paid_at is null;
    insert into payroll_transfer_paid_marks(line_id, batch_id, journal_record_id, user_id, year_month, paid_at_set, paid_by_set, basis, marked_by)
    values (v_l.id, p_batch_id, v_j.id, v_l.user_id, v_l.year_month, v_at, v_by, v_l.line_status, v_uid)
    on conflict (line_id) do update set journal_record_id = excluded.journal_record_id, paid_at_set = excluded.paid_at_set, paid_by_set = excluded.paid_by_set,
      basis = excluded.basis, marked_by = excluded.marked_by, marked_at = now(), cleared_at = null, cleared_by = null, cleared_reason = null;
    v_marked := v_marked + 1;
  end loop;
  return jsonb_build_object('ok', true, 'marked', v_marked, 'already_paid', v_already, 'marked_before', v_done_before, 'no_journal', v_no_journal,
                            'multiple_journal_rows', v_multi, 'not_final', v_not_final);
end $$
;

CREATE OR REPLACE FUNCTION public.payroll_transfer_task_check(p_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  v_uid uuid := auth.uid(); v_b payroll_transfer_batches%rowtype; v_task uuid; v_step uuid; v_tasks integer;
  v_l record; v_name text; v_same integer; v_items integer; v_item hq_step_checklist_items%rowtype; v_by uuid; v_at timestamptz;
  v_checked integer := 0; v_already integer := 0; v_no_item integer := 0; v_ambiguous integer := 0; v_not_final integer := 0; v_before integer := 0;
  v_total integer; v_done integer; v_title text; v_was_done boolean; v_completed boolean := false;
begin
  if not (public.payroll_recon_is_service() or (v_uid is not null and public.payroll_pay_can() is true)) then raise exception '権限がありません（給与の担当者としてログインしてください）'; end if;   -- 2026-12-08: 自動の反映（service_role）も通す
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
end $$
;

CREATE OR REPLACE FUNCTION public.payroll_recon_complete(p_batch_id uuid, p_kind text, p_actor_kind text, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare v_old text; v_old_kind text;
begin
  select b.status, b.completed_kind into v_old, v_old_kind from payroll_transfer_batches b where b.id = p_batch_id;
  if v_old = 'completed' and v_old_kind is not distinct from p_kind then return; end if;
  update payroll_transfer_batch_lines l set line_status = 'completed', status_reason = null, completed_at = coalesce(l.completed_at, now()), updated_at = now()
   where l.batch_id = p_batch_id and l.bank_detail_id is not null and l.line_status = 'bank_matched';
  update payroll_transfer_batches b
     set status = 'completed', status_reason = null, completed_at = coalesce(b.completed_at, now()), completed_kind = p_kind,
         completed_by = auth.uid(), updated_at = now()
   where b.id = p_batch_id;
  perform public.payroll_recon_log(p_batch_id, null, 'batch_status', v_old, 'completed', p_actor_kind, p_note, jsonb_build_object('completed_kind', p_kind));
  -- 2026-12-08: 自動で完了したとき（かつスイッチ auto_reflect が true）だけ、給与の「振込済」と本部タスクのチェックへ反映する。失敗しても完了は戻さない。
  if p_kind = 'auto' and public.payroll_recon_flag('auto_reflect') then
    begin
      perform public.payroll_transfer_paid_backfill(p_batch_id);
      perform public.payroll_transfer_task_check(p_batch_id);
    exception when others then
      perform public.payroll_recon_log(p_batch_id, null, 'batch_status', 'completed', 'completed', p_actor_kind, '自動の反映に失敗しました: ' || left(sqlerrm, 200), jsonb_build_object('reflect_failed', true));
    end;
  end if;
end $$
;
