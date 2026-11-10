-- ============================================================
-- 2026-11-10 担当B（nippo）— U-27「給料確定ボタンを押した後に取り消せるようにしたい」: hq_cancel_payroll_tasks
-- 【状態】事前報告（未適用・実装はユーザー承認後）。前提: 2026-11-09_payroll_finalized_cash_cancel.sql 適用済み
-- 【シグネチャ】hq_cancel_payroll_tasks(p_year_month text, p_corp_id uuid, p_reason text) returns jsonb
--   権限は hq_create_payroll_tasks と同じ（マスター・本部・社長）。理由必須（200文字まで）
-- 【動き】①その月×法人が確定済みか確認 ②現金手渡しのサイン記録(その月×法人の契約)に、渡した側/受取側/完了/引き出しのどれかがあれば取消不可（先に現金手渡し画面で個別取消）
--   ③確定が作った本部タスク（payroll_task_links）を点検:
--     ・確定が新規に作ったタスク（テンプレ由来でない）: 「未着手 かつ 工程完了0 かつ チェック済み0」なら論理削除（deleted_at）。1件でも進んでいれば【エラーで停止】し何も変えない（進捗は消さない）
--     ・テンプレ由来に工程を足して紐づけたもの: 足した工程だけ外す（チェック済み0・未完了のとき）。タスク本体は残す。進んでいれば停止
--   ④linksを削除 ⑤payroll_finalized の該当行を削除（＝現金手渡し画面から消える） ⑥取消履歴(payroll_finalize_cancellations)に 誰が・いつ・理由・対象タスク を記録
--   ⑦#本部-経理監視へ通知（月・法人・理由。氏名なし）。全部同一トランザクション（途中で失敗すれば何も変わらない）
-- 【再確定】取消後に給料確定ボタンを押せば、linksが無いので新規に作り直す／テンプレ由来には工程を足し直す（二重にならない）
-- 【paid_at】給与仕訳の「振込完了」印は戻さない（確定の取消とは別の事実）。印が付いた仕訳が残っている場合は通知と戻り値で知らせる
-- 【rollback】drop function hq_cancel_payroll_tasks; drop table payroll_finalize_cancellations（取消した確定は、同じ月×法人で給料確定ボタンを押し直せば戻る）
-- ============================================================

create table if not exists payroll_finalize_cancellations (
  id uuid primary key default gen_random_uuid(),
  year_month text not null,
  corporation_id uuid not null references corporations(id),
  cancelled_at timestamptz not null default now(),
  cancelled_by uuid references users(id),
  reason text not null,
  finalized_at timestamptz,
  finalized_by uuid references users(id),
  tasks jsonb not null default '[]'::jsonb,   -- [{kind, task_id, mode: 'deleted'|'step_removed'|'already_gone'}]
  paid_marked integer not null default 0      -- 取消時点で「振込完了」印が付いたままの給与仕訳の件数
);
comment on table payroll_finalize_cancellations is '給料確定の取消履歴（担当B・2026-11-10）。書き込みは hq_cancel_payroll_tasks 経由のみ';
alter table payroll_finalize_cancellations enable row level security;
revoke all on payroll_finalize_cancellations from public, anon;
drop policy if exists payroll_finalize_cancellations_read on payroll_finalize_cancellations;
create policy payroll_finalize_cancellations_read on payroll_finalize_cancellations for select to authenticated using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
);
grant select on payroll_finalize_cancellations to authenticated;

create or replace function public.hq_cancel_payroll_tasks(p_year_month text, p_corp_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_caller users%rowtype; v_reason text := btrim(coalesce(p_reason,''));
  v_fin payroll_finalized%rowtype; v_corp_name text; v_contracts text[]; v_tenants text[];
  v_sign int; v_link record; v_task hq_tasks%rowtype; v_step hq_task_steps%rowtype;
  v_prog int; v_errs text := ''; v_plan jsonb := '[]'::jsonb; v_paid int := 0; v_label text;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ')) then
    raise exception '権限がありません（マスター・本部・社長のみ）';
  end if;
  if p_year_month !~ '^\d{4}-\d{2}$' then raise exception 'year_monthは YYYY-MM 形式で指定してください'; end if;
  if length(v_reason) < 1 or length(v_reason) > 200 then raise exception '取消の理由を入力してください（200文字まで）'; end if;

  select * into v_fin from payroll_finalized where year_month = p_year_month and corporation_id = p_corp_id;
  if v_fin.year_month is null then raise exception 'この月・この会社は給料確定されていません'; end if;
  select name into v_corp_name from corporations where id = p_corp_id;
  select array_agg(sc.contract_id), array_agg(distinct case sc.corporation_hint when 'toho' then 'default' else sc.corporation_hint end)
    into v_contracts, v_tenants from smaregi_contracts sc where sc.corporation_id = p_corp_id and sc.is_active;

  -- (c) 現金手渡しのサイン記録が進んでいれば取消不可（先に個別取消）
  select count(*) into v_sign from sf_cash_handoff_signatures s
   where s.year_month = p_year_month and s.contract_id = any(coalesce(v_contracts, array[]::text[]))
     and (s.payer_checked_at is not null or s.receiver_checked_at is not null or s.completed_at is not null or s.withdrawn_at is not null);
  if v_sign > 0 then
    raise exception '現金手渡しの記録（サイン・引き出し確認など）が%件あるため、給料確定は取り消せません。先に「現金手渡し・サイン」画面で個別に取り消してください', v_sign;
  end if;

  -- (b) 1周目: 点検だけ（1件でも進んでいれば何も変えずに止める）
  for v_link in select * from payroll_task_links where year_month = p_year_month and corporation_id = p_corp_id loop
    v_label := case v_link.kind when 'transfer' then '給料振込' else '現金手渡し' end;
    select * into v_task from hq_tasks where id = v_link.task_id;
    if v_task.id is null or v_task.deleted_at is not null then continue; end if;      -- 既に消えている／手動で削除済みは対象外（linksだけ外す）
    if v_task.template_id is not null then
      select * into v_step from hq_task_steps where id = v_link.step_id;
      select count(*) into v_prog from hq_step_checklist_items where step_id = v_link.step_id and checked_at is not null;
      if coalesce(v_prog,0) > 0 or v_step.completed_at is not null then
        v_errs := v_errs || E'\n・'||v_label||'（既存タスクに足した確認工程）が進んでいます（チェック済み '||coalesce(v_prog,0)||'件）';
      end if;
    else
      select (select count(*) from hq_task_steps st where st.task_id = v_task.id and st.completed_at is not null)
           + (select count(*) from hq_step_checklist_items i join hq_task_steps st on st.id = i.step_id where st.task_id = v_task.id and i.checked_at is not null)
        into v_prog;
      if v_task.status <> 'todo' or coalesce(v_prog,0) > 0 then
        v_errs := v_errs || E'\n・'||v_label||'タスクが進行中です（状態='||v_task.status||'・完了/チェック済み '||coalesce(v_prog,0)||'件）';
      end if;
    end if;
  end loop;
  if v_errs <> '' then
    raise exception '本部タスクが進んでいるため、給料確定は取り消せません。進捗は消しません。該当タスクを個別に対応してください:%', v_errs;
  end if;

  -- 2周目: 実行
  for v_link in select * from payroll_task_links where year_month = p_year_month and corporation_id = p_corp_id loop
    select * into v_task from hq_tasks where id = v_link.task_id;
    if v_task.id is null or v_task.deleted_at is not null then
      v_plan := v_plan || jsonb_build_object('kind', v_link.kind, 'task_id', v_link.task_id, 'mode', 'already_gone');
    elsif v_task.template_id is not null then
      delete from hq_task_steps where id = v_link.step_id;                             -- チェック項目は cascade で一緒に消える（チェック済み0を確認済み）
      v_plan := v_plan || jsonb_build_object('kind', v_link.kind, 'task_id', v_link.task_id, 'mode', 'step_removed');
    else
      update hq_tasks set deleted_at = now() where id = v_task.id;                      -- 論理削除（一覧から消えるだけ）
      v_plan := v_plan || jsonb_build_object('kind', v_link.kind, 'task_id', v_link.task_id, 'mode', 'deleted');
    end if;
  end loop;
  delete from payroll_task_links where year_month = p_year_month and corporation_id = p_corp_id;
  delete from payroll_finalized where year_month = p_year_month and corporation_id = p_corp_id;

  begin
    select count(*) into v_paid from payroll_journal_records j
     where j.year_month = p_year_month and j.paid_at is not null and j.tenant_id = any(coalesce(v_tenants, array[]::text[]));
  exception when undefined_table then v_paid := 0;
  end;
  insert into payroll_finalize_cancellations(year_month, corporation_id, cancelled_by, reason, finalized_at, finalized_by, tasks, paid_marked)
  values (p_year_month, p_corp_id, auth.uid(), v_reason, v_fin.finalized_at, v_fin.finalized_by, v_plan, v_paid);

  begin
    perform notify_lark('↩️ 給料確定を取消しました: '||p_year_month||'・'||coalesce(v_corp_name,'')||'／理由: '||v_reason
      ||case when v_paid > 0 then E'\n⚠️ 「振込完了」印が付いた給与仕訳が'||v_paid||'件残っています（印は戻していません）' else '' end);
  exception when others then null;
  end;
  return jsonb_build_object('ok', true, 'corporation', v_corp_name, 'tasks', v_plan, 'paid_marked', v_paid);
end;
$function$;
revoke all on function public.hq_cancel_payroll_tasks(text, uuid, text) from public, anon;
grant execute on function public.hq_cancel_payroll_tasks(text, uuid, text) to authenticated;

-- ■適用後の確認（読み取り・実データの取消は押さない）
select proname, pg_get_function_identity_arguments(oid) as 引数, prosecdef from pg_proc where proname = 'hq_cancel_payroll_tasks' and pronamespace = 'public'::regnamespace;
select a.grantee::regrole::text as grantee, a.privilege_type from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
 where p.proname = 'hq_cancel_payroll_tasks' and p.pronamespace = 'public'::regnamespace order by 1;
