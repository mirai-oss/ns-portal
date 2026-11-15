-- 本部タスク「給与振込確認」: 名簿が全員チェック済みになったら、チェックの方法に関係なく、タスクも自動で完了にする（2026-11-15・社長の指示）
--
-- これまで: 照合の結果を名簿に反映したとき（payroll_transfer_task_check）だけ、全員チェック済みで完了になった。
--           本部タスクの画面で、人が最後の 1 人を手でチェックしたときは、完了にならなかった（人が工程を完了にする作り）。
-- 直し:   名簿の項目にチェックが入ったとき、その工程の名簿が全員チェック済みなら、工程を完了にする（タスクの状態は、既存の計算 hq_task_recalc_status が「完了」にする）。
--
-- 対象は「給与振込確認」のタスクだけ:
--   transfer_confirm_task_links の kind='payroll' に結び付いていて、題名が「給与振込確認」で始まり、削除されていないタスク。
--   取引先の振込確認（kind が payroll 以外）・そのほかの本部タスクの完了の条件は、変えない。
-- 名簿のチェックの意味: このタスクの名簿は、本部の「振込先を確認」の作業のチェック（人が確かめた印、または照合で確かめた人への反映）。
--   タスクの完了は、作業の完了を表すだけで、振込照合の状態や、給与の画面の「振込済」を変えない（＝未確認の振込を、振込済みにはしない）。
-- 守り:
--   ・1 人でも未チェックなら完了にしない。
--   ・確認待ちで振込データから除外した人が残っている月は、既存の見張り（payroll_transfer_confirm_step_guard）が完了を止める。
--     その場合は、チェックはそのまま通し、完了だけ見送る（チェックの操作をエラーにしない）。
--   ・完了の知らせ（既存の notify_lark → Slack の本部の監視チャンネル）は、初めて完了になったときの 1 回だけ。
-- 足すもの: 関数 1 本・トリガー 1 本（表 hq_step_checklist_items）。既存の関数・トリガーは変えない。
-- 戻し方: 2026-12-08_payroll_transfer_task_autocomplete_rollback.sql

create or replace function public.payroll_transfer_task_autocomplete()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  v_task uuid; v_title text; v_status text; v_step_done timestamptz; v_total integer; v_done integer;
begin
  if not (new.checked_at is not null and old.checked_at is null) then return null; end if;
  select s.task_id, s.completed_at into v_task, v_step_done from hq_task_steps s where s.id = new.step_id;
  if v_task is null or v_step_done is not null then return null; end if;
  -- 「給与振込確認」のタスクだけ
  select t.title, t.status into v_title, v_status
    from hq_tasks t
   where t.id = v_task and t.deleted_at is null and t.title like '給与振込確認%'
     and exists (select 1 from transfer_confirm_task_links k where k.kind = 'payroll' and k.hq_task_id = t.id);
  if v_title is null then return null; end if;
  select count(*), count(*) filter (where i.checked_at is not null) into v_total, v_done from hq_step_checklist_items i where i.step_id = new.step_id;
  if not (v_total > 0 and v_total = v_done) then return null; end if;   -- 1 人でも未チェックなら、完了にしない
  begin
    update hq_task_steps s set completed_at = now(), completed_by = coalesce(auth.uid(), new.checked_by)
     where s.id = new.step_id and s.completed_at is null;
  exception when others then
    return null;   -- 既存の見張りが完了を止めた（除外した人の振込が残っている など）。チェックは通し、完了は見送る
  end;
  if v_status is distinct from 'done' then
    begin
      perform notify_lark('✅ ' || v_title || ' が完了しました（全' || v_total || '件チェック済み）');
    exception when others then null;   -- 知らせの失敗で、チェックの操作を止めない
    end;
  end if;
  return null;
end $$;
revoke all on function public.payroll_transfer_task_autocomplete() from public, anon, authenticated;

drop trigger if exists payroll_transfer_task_autocomplete on public.hq_step_checklist_items;
create trigger payroll_transfer_task_autocomplete after update of checked_at on public.hq_step_checklist_items
  for each row when (new.checked_at is not null and old.checked_at is null)
  execute function public.payroll_transfer_task_autocomplete();
