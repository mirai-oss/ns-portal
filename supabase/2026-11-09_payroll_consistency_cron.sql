-- 2026-11-09 担当B — 給与・現金手渡しの毎朝の整合チェックを cron に登録（ユーザー方針: 自動化＋ミスはアラート）
-- 【前提】2026-11-09_payroll_finalized_cash_cancel.sql 適用済み（payroll_consistency_check がある）
-- 【内容】毎朝 09:50 JST に payroll_consistency_check(true) を実行。問題が無ければ何も通知しない（静か）。問題があれば Lark/Slack に件数だけ通知
-- 【影響】読み取りと通知のみ。データは変更しない
-- 【追加】本体SQLの payroll_consistency_check を修正版に置き換える（過去月のbackfill行＝finalized_by無し を「確定済みなのにタスク無し」の対象から外す。10月が毎朝誤警報になるのを防ぐ）
-- 【rollback】select cron.unschedule('payroll-consistency-check');
create or replace function public.payroll_consistency_check(p_notify boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_from text := to_char((now() at time zone 'Asia/Tokyo') - interval '3 months', 'YYYY-MM');
  c1 int; c2 int; c3 int; v_msg text := '';
begin
  select count(*) into c1
    from sf_cash_handoff_signatures s
    join users u on u.id = s.user_id
    join smaregi_contracts sc on sc.contract_id = s.contract_id
    join payroll_task_links l on l.year_month = s.year_month and l.kind = 'cash' and l.corporation_id = sc.corporation_id
    join hq_step_checklist_items i on i.step_id = l.step_id
         and replace(replace(i.title,' ',''),chr(12288),'') = replace(replace(u.name,' ',''),chr(12288),'') and i.checked_at is null
   where s.completed_at is not null and s.year_month >= v_from;
  select count(*) into c2
    from sf_cash_handoff_signatures s
    join smaregi_contracts sc on sc.contract_id = s.contract_id
   where s.completed_at is not null and s.year_month >= v_from
     and exists (select 1 from payroll_journal_records j where j.user_id = s.user_id and j.year_month = s.year_month
                    and j.tenant_id = (case sc.corporation_hint when 'toho' then 'default' else sc.corporation_hint end) and j.paid_at is null);
  select count(*) into c3
    from payroll_finalized f
   where f.year_month >= v_from
     and f.finalized_by is not null   -- 過去分のbackfill行(finalized_by無し)は対象外（ボタン未使用の過去月で誤警報にしない）
     and not exists (select 1 from payroll_task_links l where l.year_month = f.year_month and l.corporation_id = f.corporation_id)
     and exists (select 1 from sf_payroll_sync sp join smaregi_contracts sc on sc.contract_id = sp.contract_id
                  where sp.year_month = f.year_month and sc.corporation_id = f.corporation_id and coalesce(sp.net_pay,0) > 0);
  if c1 > 0 then v_msg := v_msg || E'\n・手渡し完了済みなのに本部タスクのチェックが付いていない人: '||c1||'名'; end if;
  if c2 > 0 then v_msg := v_msg || E'\n・手渡し完了済みなのに給与仕訳の「振込完了」印が付いていない人: '||c2||'名'; end if;
  if c3 > 0 then v_msg := v_msg || E'\n・給料確定済みなのに本部タスクが1件も無い月×法人: '||c3||'件'; end if;
  if v_msg <> '' and p_notify then
    perform notify_lark('⚠️ 給与・現金手渡しの整合チェック（毎朝・直近3か月）'||v_msg||E'\n解消されるまで毎朝お知らせします。nippo「現金手渡し・サイン」と本部タスクを確認してください');
  end if;
  return jsonb_build_object('tasks_unchecked', c1, 'paid_unmarked', c2, 'finalized_without_tasks', c3);
end;
$function$;
revoke all on function public.payroll_consistency_check(boolean) from public, anon, authenticated;
grant execute on function public.payroll_consistency_check(boolean) to service_role;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'payroll-consistency-check') then perform cron.unschedule('payroll-consistency-check'); end if;
  perform cron.schedule('payroll-consistency-check', '50 0 * * *', $cmd$select public.payroll_consistency_check(true)$cmd$);   -- 00:50 UTC = 09:50 JST
end $$;
select jobname, schedule, active from cron.job where jobname = 'payroll-consistency-check';
