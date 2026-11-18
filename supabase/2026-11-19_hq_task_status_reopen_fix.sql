-- 2026-11-19 担当B（社長の承認）— 本部タスクが「完了」のまま戻らない不具合を直す
-- 【原因】タスクの状態を工程から自動計算する関数 hq_task_recalc_status が、「完了」→「進行中」への戻しをしていなかった。
--        そのため、(a) 全工程を完了したあとに、工程を足した／完了を取り消した場合、タスクだけ「完了」のまま残り、Slack で「完了したタスクは直せません」と出る。
-- 【直し】工程が 1 つでも未完了なら、状態が「完了」でも「進行中」に戻し、完了日時を空にする（関数の 2 か所だけ置き換え。中身が想定と違えば何も変えずに止まる）。
-- 【あわせて】社長のテストタスク「ポータルの「いまここ」機能の修正」（工程が未完了なのに「完了」になっている）だけ、いま「進行中」に戻す。
--   ほかの 3 件（入金確認・イプシロン・10月分【振込トーホー】給料）も同じ状態だが、戻すと未完了の工程の通知が始まるため、ここでは触らない（社長に確認してから）。
-- 【戻し方】2026-08-10_hq_tasks.sql の hq_task_recalc_status を流し直す
do $do$
declare v_oid oid; v_def text; v_new text; v_a constant text := 'status=''doing'', updated_at = now()'; v_b constant text := 'and status = ''todo'';';
begin
  select p.oid into v_oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = 'hq_task_recalc_status';
  if v_oid is null then raise exception '停止: 関数 hq_task_recalc_status がありません'; end if;
  v_def := pg_get_functiondef(v_oid);
  if position('status in (''todo'', ''done'')' in v_def) > 0 or position('status in (''todo'',''done'')' in v_def) > 0 then raise notice 'すでに直っています（関数は何もしません）';
  else
    if (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a) <> 1 or (length(v_def) - length(replace(v_def, v_b, ''))) / length(v_b) <> 1 then
      raise exception '停止: 関数の中身が想定と違います（変えずに止めました）';
    end if;
    v_new := replace(replace(v_def, v_a, 'status=''doing'', completed_at = null, updated_at = now()'), v_b, 'and status in (''todo'', ''done'');');
    execute v_new;
    raise notice 'hq_task_recalc_status を直しました';
  end if;
end $do$;

update public.hq_tasks set status = 'doing', completed_at = null, updated_at = now()
 where id = 'bc23b1b7-c871-455b-8570-af7b27f8c14a' and status = 'done'
   and exists (select 1 from public.hq_task_steps s where s.task_id = hq_tasks.id and s.completed_at is null);
