-- ============================================================
-- 2026-11-10 担当B（nippo）— U-27「給料確定ボタンを押した後に取り消せるようにしたい」
-- 【状態】事前報告（未適用・実装はユーザー承認後）。前提: 2026-11-09_payroll_finalized_cash_cancel.sql 適用済み
-- 【仕様（ユーザー回答 2026-11-10・追加指示反映）】確定の取消で、本部タスク（進行中も含む）は自動で取り消す。現金手渡しのサインが1人でもあるときは、画面（担当C）が人数・名前を見せて
--   「そのまま残す」(p_cancel_signatures=false) か「取り消す」(=true) を選ばせる。1トランザクション・失敗時は全て戻す
-- 【RPC】権限=確定(hq_create_payroll_tasks)と同じ（マスター・本部・社長）
--   ① hq_cancel_payroll_preview(p_year_month text, p_corp_id uuid) returns jsonb   … 確認ダイアログ用の事前件数（何も変更しない）
--      {finalized, corporation, tasks, tasks_in_progress, tasks_delete, steps_remove, signed:[{user_id,name,completed}], sign_people, sign_completed, paid_marked, mf_registered}
--   ② hq_cancel_payroll_tasks(p_year_month text, p_corp_id uuid, p_reason text, p_cancel_signatures boolean default false) returns jsonb   … 実行（理由必須・200文字まで）
--      {ok, corporation, tasks_cancelled, tasks_in_progress_cancelled, steps_removed, signatures_cancelled, finalized_removed, paid_reset, mf_registered}
--      p_cancel_signatures=false（既定）: サインは残す（データは残るが、確定を外すので手渡し画面からは隠れ、再確定で再表示）。paid_atにも触れない
-- 【動き】
--   本部タスク: 確定が新規に作ったタスク=論理削除（進行中も対象・deleted_at）／テンプレ由来に足した「振込対象者の確認」工程=工程だけ外す（タスク本体は残す）→ payroll_task_links を削除
--   現金手渡し: その月×法人の契約のサイン記録のうち、サイン・確認・完了・引き出しのどれかがある行を cash_handoff_cancel と同じ扱いで取消（理由「給料確定の取消: …」・履歴に戻す前の状態と元の画像パス）
--   ※p_cancel_signatures=true のときだけ。サイン画像は消さない（storage上にそのまま残し、履歴にorig_*パスを保存。SQLからはstorageの別名コピーができないため。画面からの個別取消ではarchive名へコピーする）
--   paid_at: 取り消したサインの人×その月×その法人の給与仕訳の「振込完了」印を戻す（cash_handoff_cancelの p_reset_paid=true と同じ）。MF登録済み仕訳は消さず件数を通知
--   最後に payroll_finalized の該当行を削除（＝現金手渡し画面から消える）→ 取消履歴(payroll_finalize_cancellations)に記録 → #本部-経理監視へ件数＋月・法人（氏名なし）
-- 【再確定】取消後に給料確定ボタンを押せば作り直せる（linksが無い＝新規作成／テンプレ由来には工程を足し直す。二重にならない）
-- 【rollback】drop function hq_cancel_payroll_tasks(text,uuid,text,boolean); drop function hq_cancel_payroll_preview(text,uuid); drop table payroll_finalize_cancellations;
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
  tasks jsonb not null default '[]'::jsonb,   -- [{kind, task_id, mode: 'deleted'|'step_removed'|'already_gone', was_in_progress}]
  sign_cancelled integer not null default 0,
  signatures_kept integer not null default 0,   -- 「そのまま残す」を選んだサイン記録の人数
  paid_reset integer not null default 0,
  mf_registered integer not null default 0
);
comment on table payroll_finalize_cancellations is '給料確定の取消履歴（担当B・2026-11-10）。書き込みは hq_cancel_payroll_tasks 経由のみ';
alter table payroll_finalize_cancellations enable row level security;
revoke all on payroll_finalize_cancellations from public, anon;
drop policy if exists payroll_finalize_cancellations_read on payroll_finalize_cancellations;
create policy payroll_finalize_cancellations_read on payroll_finalize_cancellations for select to authenticated using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
);
grant select on payroll_finalize_cancellations to authenticated;

-- ① 事前件数（何も変更しない）
create or replace function public.hq_cancel_payroll_preview(p_year_month text, p_corp_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_caller users%rowtype; v_fin payroll_finalized%rowtype; v_corp_name text; v_contracts text[]; v_tenants text[];
  v_link record; v_task hq_tasks%rowtype; v_prog int; v_total int := 0; v_inprog int := 0; v_del int := 0; v_step int := 0;
  v_sign int; v_signdone int; v_paid int := 0; v_mf int := 0; v_signed jsonb;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ')) then
    raise exception '権限がありません（マスター・本部・社長のみ）';
  end if;
  select * into v_fin from payroll_finalized where year_month = p_year_month and corporation_id = p_corp_id;
  select name into v_corp_name from corporations where id = p_corp_id;
  select array_agg(sc.contract_id), array_agg(distinct case sc.corporation_hint when 'toho' then 'default' else sc.corporation_hint end)
    into v_contracts, v_tenants from smaregi_contracts sc where sc.corporation_id = p_corp_id and sc.is_active;
  for v_link in select * from payroll_task_links where year_month = p_year_month and corporation_id = p_corp_id loop
    select * into v_task from hq_tasks where id = v_link.task_id;
    if v_task.id is null or v_task.deleted_at is not null then continue; end if;
    v_total := v_total + 1;
    if v_task.template_id is not null then
      v_step := v_step + 1;
      select count(*) into v_prog from hq_step_checklist_items where step_id = v_link.step_id and checked_at is not null;
    else
      v_del := v_del + 1;
      select (select count(*) from hq_task_steps st where st.task_id = v_task.id and st.completed_at is not null)
           + (select count(*) from hq_step_checklist_items i join hq_task_steps st on st.id = i.step_id where st.task_id = v_task.id and i.checked_at is not null)
        into v_prog;
      if v_task.status <> 'todo' then v_prog := v_prog + 1; end if;
    end if;
    if coalesce(v_prog,0) > 0 then v_inprog := v_inprog + 1; end if;
  end loop;
  select count(*), count(*) filter (where s.completed_at is not null) into v_sign, v_signdone
    from sf_cash_handoff_signatures s
   where s.year_month = p_year_month and s.contract_id = any(coalesce(v_contracts, array[]::text[]))
     and (s.payer_checked_at is not null or s.receiver_checked_at is not null or s.completed_at is not null or s.withdrawn_at is not null);
  select coalesce(jsonb_agg(jsonb_build_object('user_id', s.user_id, 'name', u.name, 'completed', s.completed_at is not null) order by u.name), '[]'::jsonb) into v_signed
    from sf_cash_handoff_signatures s join users u on u.id = s.user_id
   where s.year_month = p_year_month and s.contract_id = any(coalesce(v_contracts, array[]::text[]))
     and (s.payer_checked_at is not null or s.receiver_checked_at is not null or s.completed_at is not null or s.withdrawn_at is not null);
  begin
    select count(*) filter (where j.paid_at is not null), count(*) filter (where j.paid_at is not null and j.mf_journal_id is not null) into v_paid, v_mf
      from payroll_journal_records j
     where j.year_month = p_year_month and j.tenant_id = any(coalesce(v_tenants, array[]::text[]))
       and j.user_id in (select s.user_id from sf_cash_handoff_signatures s where s.year_month = p_year_month and s.contract_id = any(coalesce(v_contracts, array[]::text[]))
                          and (s.payer_checked_at is not null or s.receiver_checked_at is not null or s.completed_at is not null or s.withdrawn_at is not null));
  exception when undefined_table then v_paid := 0; v_mf := 0;
  end;
  return jsonb_build_object('finalized', v_fin.year_month is not null, 'corporation', v_corp_name,
    'tasks', v_total, 'tasks_total', v_total, 'tasks_in_progress', v_inprog, 'signed', v_signed, 'tasks_delete', v_del, 'steps_remove', v_step,
    'sign_people', v_sign, 'sign_completed', v_signdone, 'paid_marked', v_paid, 'mf_registered', v_mf);
end;
$function$;
revoke all on function public.hq_cancel_payroll_preview(text, uuid) from public, anon;
grant execute on function public.hq_cancel_payroll_preview(text, uuid) to authenticated;

-- ② 実行
create or replace function public.hq_cancel_payroll_tasks(p_year_month text, p_corp_id uuid, p_reason text, p_cancel_signatures boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_caller users%rowtype; v_reason text := btrim(coalesce(p_reason,''));
  v_fin payroll_finalized%rowtype; v_corp_name text; v_contracts text[]; v_tenants text[];
  v_link record; v_task hq_tasks%rowtype; v_plan jsonb := '[]'::jsonb; v_prog int; v_inprog boolean;
  v_row sf_cash_handoff_signatures%rowtype; v_sign int := 0; v_paid int := 0; v_mf int := 0; v_n int; v_del int := 0; v_stp int := 0; v_inprog_n int := 0; v_kept int := 0;
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

  -- 本部タスク
  for v_link in select * from payroll_task_links where year_month = p_year_month and corporation_id = p_corp_id loop
    select * into v_task from hq_tasks where id = v_link.task_id;
    if v_task.id is null or v_task.deleted_at is not null then
      v_plan := v_plan || jsonb_build_object('kind', v_link.kind, 'task_id', v_link.task_id, 'mode', 'already_gone', 'was_in_progress', false);
    elsif v_task.template_id is not null then
      select count(*) into v_prog from hq_step_checklist_items where step_id = v_link.step_id and checked_at is not null;
      delete from hq_task_steps where id = v_link.step_id;                               -- 足した工程だけ外す（チェック項目はcascade）。タスク本体は残す
      v_stp := v_stp + 1;
      v_plan := v_plan || jsonb_build_object('kind', v_link.kind, 'task_id', v_link.task_id, 'mode', 'step_removed', 'was_in_progress', coalesce(v_prog,0) > 0);
    else
      select (select count(*) from hq_task_steps st where st.task_id = v_task.id and st.completed_at is not null)
           + (select count(*) from hq_step_checklist_items i join hq_task_steps st on st.id = i.step_id where st.task_id = v_task.id and i.checked_at is not null)
        into v_prog;
      v_inprog := coalesce(v_prog,0) > 0 or v_task.status <> 'todo';
      update hq_tasks set deleted_at = now() where id = v_task.id;                        -- 論理削除（進行中も）
      v_del := v_del + 1; if v_inprog then v_inprog_n := v_inprog_n + 1; end if;
      v_plan := v_plan || jsonb_build_object('kind', v_link.kind, 'task_id', v_link.task_id, 'mode', 'deleted', 'was_in_progress', v_inprog);
    end if;
  end loop;
  delete from payroll_task_links where year_month = p_year_month and corporation_id = p_corp_id;

  -- 現金手渡しのサイン（cash_handoff_cancel と同じ扱い）
  for v_row in select * from sf_cash_handoff_signatures s
                where s.year_month = p_year_month and s.contract_id = any(coalesce(v_contracts, array[]::text[]))
                  and (s.payer_checked_at is not null or s.receiver_checked_at is not null or s.completed_at is not null or s.withdrawn_at is not null) loop
    if not coalesce(p_cancel_signatures, false) then v_kept := v_kept + 1; continue; end if;   -- 「そのまま残す」
    insert into sf_cash_handoff_cancellations(user_id, year_month, contract_id, corporation_id, cancelled_by, reason,
        prev_payer_id, prev_payer_checked_at, prev_receiver_checked_at, prev_completed_at, archived_paths, paid_at_reset)
    values (v_row.user_id, v_row.year_month, v_row.contract_id, p_corp_id, auth.uid(), '給料確定の取消: '||v_reason,
        v_row.payer_id, v_row.payer_checked_at, v_row.receiver_checked_at, v_row.completed_at,
        jsonb_build_object('orig_payer_signature', v_row.payer_signature_path, 'orig_receiver_signature', v_row.receiver_signature_path, 'orig_handoff_photo', v_row.handoff_photo_path), 0);
    update sf_cash_handoff_signatures set
        payer_id = null, payer_checked_at = null, payer_signature_path = null, handoff_photo_path = null,
        receiver_checked_at = null, receiver_signature_path = null, completed_at = null,
        withdrawn_at = null, withdrawn_by = null, withdrawn_photo_path = null, updated_at = now()
     where id = v_row.id;
    v_sign := v_sign + 1;
    begin
      select count(*) into v_n from payroll_journal_records j
       where j.user_id = v_row.user_id and j.year_month = p_year_month and j.paid_at is not null and j.mf_journal_id is not null
         and j.tenant_id = any(coalesce(v_tenants, array[]::text[]));
      v_mf := v_mf + coalesce(v_n,0);
      update payroll_journal_records set paid_at = null, paid_by = null
       where user_id = v_row.user_id and year_month = p_year_month and paid_at is not null
         and tenant_id = any(coalesce(v_tenants, array[]::text[]));
      get diagnostics v_n = row_count;
      v_paid := v_paid + v_n;
    exception when undefined_table then null;
    end;
  end loop;

  delete from payroll_finalized where year_month = p_year_month and corporation_id = p_corp_id;
  insert into payroll_finalize_cancellations(year_month, corporation_id, cancelled_by, reason, finalized_at, finalized_by, tasks, sign_cancelled, signatures_kept, paid_reset, mf_registered)
  values (p_year_month, p_corp_id, auth.uid(), v_reason, v_fin.finalized_at, v_fin.finalized_by, v_plan, v_sign, v_kept, v_paid, v_mf);

  begin
    perform notify_lark('↩️ 給料確定を取消しました: '||p_year_month||'・'||coalesce(v_corp_name,'')||'／理由: '||v_reason
      ||E'\n本部タスク取消'||v_del||'件（うち進行中'||v_inprog_n||'件）・工程の取り外し'||v_stp||'件・現金手渡しサイン取消'||v_sign||'名'||case when v_kept > 0 then '（'||v_kept||'名は残した）' else '' end||'・振込完了印を戻した給与仕訳'||v_paid||'件'
      ||case when v_mf > 0 then E'\n⚠️ 会計ソフト(MF)に登録済みの仕訳が'||v_mf||'件あります。自動では消していないので、必要なら会計側で確認してください' else '' end);
  exception when others then null;
  end;
  return jsonb_build_object('ok', true, 'corporation', v_corp_name, 'tasks_cancelled', v_del + v_stp, 'tasks_in_progress_cancelled', v_inprog_n,
    'tasks_deleted', v_del, 'steps_removed', v_stp, 'signatures_cancelled', v_sign, 'signatures_kept', v_kept, 'finalized_removed', true,
    'paid_reset', v_paid, 'mf_registered', v_mf);
end;
$function$;
revoke all on function public.hq_cancel_payroll_tasks(text, uuid, text, boolean) from public, anon;
grant execute on function public.hq_cancel_payroll_tasks(text, uuid, text, boolean) to authenticated;

-- ■適用後の確認（読み取り・実データの取消は押さない）
select proname, pg_get_function_identity_arguments(oid) as 引数, prosecdef from pg_proc
 where proname in ('hq_cancel_payroll_tasks','hq_cancel_payroll_preview') and pronamespace = 'public'::regnamespace order by 1;
select p.proname, a.grantee::regrole::text as grantee, a.privilege_type from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
 where p.proname in ('hq_cancel_payroll_tasks','hq_cancel_payroll_preview') and p.pronamespace = 'public'::regnamespace order by 1, 2;
