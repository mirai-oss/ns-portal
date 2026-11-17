-- 2026-11-17_payroll_transfer_task_per_corp.sql の戻し（変更前の本番の定義へ）

CREATE OR REPLACE FUNCTION public.hq_upsert_transfer_task(p_kind text, p_scope_key text, p_transfer_date date, p_recipient_names text[], p_corp text DEFAULT 'N-Style'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_task_id uuid;
  v_step_id uuid;
  v_task_status text;
  v_assignees uuid[];
  v_uid uuid;
  v_title text;
  v_name text;
  v_sort int;
  v_existing_task uuid;   -- 2026-11-11 修正: record 型の変数のフィールドへ、値を入れる前に代入していたため必ずエラーになっていた
begin
  if auth.uid() is null or not exists(select 1 from users u where u.id = auth.uid() and u.is_active) then
    raise exception '認証が必要です';
  end if;
  if p_transfer_date is null then
    raise exception '振込予定日が必要です';
  end if;
  if p_scope_key is null or trim(p_scope_key) = '' then
    raise exception 'scope_keyが必要です';
  end if;
  if p_recipient_names is null or array_length(p_recipient_names,1) is null then
    raise exception '振込先の名前が1件も指定されていません';
  end if;

  v_title := case when p_kind = 'payroll' then '給与振込確認' else '取引先振込確認' end
    || '（振込予定日: ' || to_char(p_transfer_date,'YYYY-MM-DD') || '）';

  -- 既存リンクを確認：同じkind×scope_keyでまだ「未完了」のタスクがあれば、それを更新するだけにする
  select l.hq_task_id, t.status into v_existing_task, v_task_status
  from transfer_confirm_task_links l join hq_tasks t on t.id = l.hq_task_id
  where l.kind = p_kind and l.scope_key = p_scope_key;

  if v_existing_task is not null and coalesce(v_task_status,'done') <> 'done' then
    -- ① 既存タスクを更新（期限・タイトルを新しい振込予定日に）
    v_task_id := v_existing_task;
    update hq_tasks set due_date = p_transfer_date, title = v_title, updated_at = now()
      where id = v_task_id;
    update hq_task_steps set due_date = p_transfer_date, updated_at = now()
      where task_id = v_task_id and sort_order = 10
      returning id into v_step_id;
    -- ② チェックリスト：既に同じ名前があれば追加しない（重複防止）。新しい名前だけ追加する
    v_sort := coalesce((select max(sort_order) from hq_step_checklist_items where step_id = v_step_id), 0) + 10;
    foreach v_name in array p_recipient_names loop
      if not exists (select 1 from hq_step_checklist_items where step_id = v_step_id and title = v_name) then
        insert into hq_step_checklist_items(step_id, title, sort_order) values (v_step_id, v_name, v_sort);
        v_sort := v_sort + 10;
      end if;
    end loop;
    update transfer_confirm_task_links set updated_at = now() where kind = p_kind and scope_key = p_scope_key;
    insert into hq_task_activity(task_id, actor_id, kind, detail)
    values (v_task_id, auth.uid(), 'comment', '振込予定日を更新（' || to_char(p_transfer_date,'YYYY-MM-DD') || '）。新規タスクは作成せず既存タスクを更新しました');
    return v_task_id;
  end if;

  -- ③ 既存の開いているタスクが無い（初回、または前回のタスクが完了済み）→ 新規作成
  v_assignees := array[]::uuid[];
  for v_uid in
    select id from users where name in ('青山純','原　美香','齋藤　隆治') and is_active
  loop
    v_assignees := array_append(v_assignees, v_uid);
  end loop;

  insert into hq_tasks (title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
  values (
    v_title, p_corp, 'once', current_date, p_transfer_date, '',
    '振込予定日: ' || to_char(p_transfer_date,'YYYY-MM-DD') || E'\n' ||
    '振込先件数: ' || array_length(p_recipient_names,1) || '件',
    'all', auth.uid()
  ) returning id into v_task_id;

  insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
  values (v_task_id, '振込先を確認', v_assignees, p_transfer_date, 10, 'step')
  returning id into v_step_id;

  v_sort := 10;
  foreach v_name in array p_recipient_names loop
    insert into hq_step_checklist_items(step_id, title, sort_order) values (v_step_id, v_name, v_sort);
    v_sort := v_sort + 10;
  end loop;

  insert into hq_task_activity(task_id, actor_id, kind, detail)
  values (v_task_id, auth.uid(), 'create',
    (case when p_kind='payroll' then '給与振込' else '取引先振込' end) || 'CSV出力により自動作成（振込予定日: ' || to_char(p_transfer_date,'YYYY-MM-DD') || '）');

  insert into transfer_confirm_task_links(kind, scope_key, hq_task_id) values (p_kind, p_scope_key, v_task_id)
  on conflict (kind, scope_key) do update set hq_task_id = excluded.hq_task_id, updated_at = now();

  return v_task_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.payroll_transfer_task_check(p_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.payroll_transfer_confirm_step_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ym text; v_names text;
begin
  if not (new.completed_at is not null and old.completed_at is null) then return new; end if;
  begin
    select l.scope_key into v_ym from transfer_confirm_task_links l where l.kind = 'payroll' and l.hq_task_id = new.task_id limit 1;
    if v_ym is not null then
      select string_agg((select name from users u where u.id = h.user_id) || 'さん', '、') into v_names from payroll_transfer_holds h where h.year_month = v_ym and h.status in ('held', 'ready');
    end if;
  exception when others then v_names := null;   -- 判定そのものの失敗では、本部タスクの操作を止めない
  end;
  if v_names is not null then
    raise exception '% 月分の給与振込は、まだ完了にできません。確認待ち（口座変更の承認待ち・未承認の賃金変更）で振込データから除外した人の振込が済んでいません（%）。申請・賃金変更の確認を済ませ、振込画面で「除外していた人の分を出力」して振り込んでから完了にしてください', v_ym, v_names;
  end if;
  return new;
end $function$;

drop function if exists public.payroll_task_scope(text, uuid);
