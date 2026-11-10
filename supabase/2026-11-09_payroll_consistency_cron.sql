-- 2026-11-09 担当B — 給与・現金手渡しの毎朝の整合チェックを cron に登録（ユーザー方針: 自動化＋ミスはアラート）
-- 【前提】2026-11-09_payroll_finalized_cash_cancel.sql 適用済み（payroll_consistency_check がある）
-- 【内容】毎朝 09:50 JST に payroll_consistency_check(true) を実行。問題が無ければ何も通知しない（静か）。問題があれば Lark/Slack に件数だけ通知
-- 【影響】読み取りと通知のみ。データは変更しない
-- 【追加】本体SQLの payroll_consistency_check を修正版に置き換える（過去月のbackfill行＝finalized_by無し を「確定済みなのにタスク無し」の対象から外す。10月が毎朝誤警報になるのを防ぐ）
-- 【rollback】select cron.unschedule('payroll-consistency-check'); select cron.unschedule('cash-handoff-incomplete-alert'); drop function cash_handoff_incomplete_alert(boolean);
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

-- 【追加2】payroll_task_links に残っていた anon の参照権限を外す（方針=PUBLIC/anonなし。画面はログイン後=authenticatedで読むので影響なし）
revoke all on public.payroll_task_links from anon;

-- 【追加3】現金手渡しの未完了アラート（ユーザー要望 2026-11-11）:「毎月25日以降で現金手渡しサインが全員分完了していない場合はSlackに通知。何月分の誰が今どの状態かが分かるように」
--   対象: 給料確定済みの月×法人のうち、期限（給与月の翌月25日）を過ぎたもの（直近2か月分まで）。対象者=現金手渡し・手取り>0・非表示でない人（画面と同じ基準）
--   通知: 月・会社・完了/未完了の人数＋未完了の方の「氏名（店舗）：サイン状況・引き出し状況」（金額は載せない）。全員完了すれば通知しない。未完了が残る間は毎朝（09:55 JST）
create or replace function public.cash_handoff_incomplete_alert(p_notify boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
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
$function$;
revoke all on function public.cash_handoff_incomplete_alert(boolean) from public, anon, authenticated;
grant execute on function public.cash_handoff_incomplete_alert(boolean) to service_role;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'payroll-consistency-check') then perform cron.unschedule('payroll-consistency-check'); end if;
  perform cron.schedule('payroll-consistency-check', '50 0 * * *', $cmd$select public.payroll_consistency_check(true)$cmd$);   -- 00:50 UTC = 09:50 JST
  if exists (select 1 from cron.job where jobname = 'cash-handoff-incomplete-alert') then perform cron.unschedule('cash-handoff-incomplete-alert'); end if;
  perform cron.schedule('cash-handoff-incomplete-alert', '55 0 * * *', $cmd$select public.cash_handoff_incomplete_alert(true)$cmd$);   -- 00:55 UTC = 09:55 JST
end $$;
select jobname, schedule, active from cron.job where jobname = 'cash-handoff-incomplete-alert';
select jobname, schedule, active from cron.job where jobname = 'payroll-consistency-check';
