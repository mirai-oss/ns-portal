-- ============================================================
-- 2026-11-10 担当B — U-27 hq_cancel_payroll_tasks / hq_cancel_payroll_preview のテスト（痕跡ゼロ: 最後に必ず ROLLBACK）
-- 【状態】未実行。SQL Editor で全体を1回実行する。前提: 2026-11-09_payroll_finalized_cash_cancel.sql 適用済み
-- 【やること】1つのトランザクション内で ①通知関数(notify_lark)を空のものに差し替え（実際には送らない） ②U-27の関数を作成（まだ本番には入らない）
--   ③未使用月 2099-01 でテストデータを作る ④権限・理由・事前件数・取消(サイン残す/取り消す)・全戻し(原子性)を assert ⑤ROLLBACK（②の関数も③のデータも全部消える）
-- 【合格】最後に「U-27 tests: 全て合格」と出て、事後確認の件数が全部0（関数も本番に残らない）。失敗時は assert のメッセージが出る（それでも ROLLBACK するので何も残らない）
-- ============================================================
begin;

-- ① 通知は送らない（このトランザクション内だけの差し替え。ROLLBACKで元に戻る）
create or replace function public.notify_lark(p_text text) returns void language plpgsql as $s$
begin perform set_config('test.last_notify', p_text, true); end $s$;

-- ② テスト対象（本番に入れるSQLと同一。ROLLBACKで消える）
-- ============================================================
-- 2026-11-10 担当B（nippo）— U-27「給料確定ボタンを押した後に取り消せるようにしたい」
-- 【状態】事前報告（未適用・実装はユーザー承認後）。前提: 2026-11-09_payroll_finalized_cash_cancel.sql 適用済み
-- 【仕様（ユーザー回答 2026-11-10・追加指示反映）】確定の取消で、本部タスク（進行中も含む）は自動で取り消す。現金手渡しのサインが1人でもあるときは、画面（担当C）が人数・名前を見せて
--   「そのまま残す」(p_cancel_signatures=false) か「取り消す」(=true) を選ばせる。1トランザクション・失敗時は全て戻す
-- 【RPC】権限=確定(hq_create_payroll_tasks)と同じ（マスター・本部・社長）
--   ① hq_cancel_payroll_preview(p_year_month text, p_corp_id uuid) returns jsonb   … 確認ダイアログ用の事前件数（何も変更しない）
--      {finalized, corporation, tasks, tasks_in_progress, tasks_delete, steps_remove, signed:[{user_id,name,completed}], sign_people, sign_completed, paid_marked, mf_registered}
--   ② hq_cancel_payroll_tasks(p_year_month text, p_corp_id uuid, p_reason text, p_cancel_signatures boolean default true) returns jsonb   … 実行（理由必須・200文字まで）
--      {ok, corporation, tasks_cancelled, tasks_in_progress_cancelled, steps_removed, signatures_cancelled, finalized_removed, paid_reset, mf_registered}
--      p_cancel_signatures=false: サインは残す（データは残るが、確定を外すので手渡し画面からは隠れ、再確定で再表示）。paid_atにも触れない
-- 【動き】
--   本部タスク: 確定が新規に作ったタスク=論理削除（進行中も対象・deleted_at）／テンプレ由来に足した「振込対象者の確認」工程=工程だけ外す（タスク本体は残す）→ payroll_task_links を削除
--   現金手渡し: その月×法人の契約のサイン記録のうち、サイン・確認・完了・引き出しのどれかがある行を cash_handoff_cancel と同じ扱いで取消（理由「給料確定の取消: …」・履歴に戻す前の状態と元の画像パス）
--   ※p_cancel_signatures=true のときだけ。サイン画像は消さない（storage上にそのまま残し、履歴にorig_*パスを保存。SQLからはstorageの別名コピーができないため。画面からの個別取消ではarchive名へコピーする）
--   paid_at: 取り消したサインの人×その月×その法人の給与仕訳の「振込完了」印を戻す（cash_handoff_cancelの p_reset_paid=true と同じ）。MF登録済み仕訳は消さず件数を通知
--   最後に payroll_finalized の該当行を削除（＝現金手渡し画面から消える）→ 取消履歴(payroll_finalize_cancellations)に記録 → #本部-経理監視へ件数＋月・法人（氏名なし）
-- 【再確定】取消後に給料確定ボタンを押せば作り直せる（linksが無い＝新規作成／テンプレ由来には工程を足し直す。二重にならない）
-- 【③】payroll_finalized_status(p_year_month text, p_corp_id uuid) returns jsonb … 給料確定ボタンの状態表示用の読み取り（同じ権限）
-- 【rollback】drop function payroll_finalized_status(text,uuid); drop function hq_cancel_payroll_tasks(text,uuid,text,boolean); drop function hq_cancel_payroll_preview(text,uuid); drop table payroll_finalize_cancellations;
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
  cancel_signatures boolean not null default true,   -- 画面で「取り消す」を選んだか（false=サインは残した）
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
create or replace function public.hq_cancel_payroll_tasks(p_year_month text, p_corp_id uuid, p_reason text, p_cancel_signatures boolean default true)
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
    if not coalesce(p_cancel_signatures, true) then v_kept := v_kept + 1; continue; end if;   -- 「そのまま残す」
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
  insert into payroll_finalize_cancellations(year_month, corporation_id, cancelled_by, reason, finalized_at, finalized_by, tasks, sign_cancelled, cancel_signatures, signatures_kept, paid_reset, mf_registered)
  values (p_year_month, p_corp_id, auth.uid(), v_reason, v_fin.finalized_at, v_fin.finalized_by, v_plan, v_sign, coalesce(p_cancel_signatures, true), v_kept, v_paid, v_mf);

  begin
    perform notify_lark('↩️ 給料確定を取消しました: '||p_year_month||'・'||coalesce(v_corp_name,'')||'／理由: '||v_reason
      ||E'\n本部タスク取消'||v_del||'件（うち進行中'||v_inprog_n||'件）・工程の取り外し'||v_stp||'件・現金手渡しサイン取消'||v_sign||'名'||case when v_kept > 0 then '（'||v_kept||'名は残した）' else '' end||'・振込完了印を戻した給与仕訳'||v_paid||'件'
      ||case when v_mf > 0 then E'\n⚠️ 会計ソフト(MF)に登録済みの仕訳が'||v_mf||'件あります。自動では消していないので、必要なら会計側で確認してください' else '' end);
  exception when others then null;
  end;
  return jsonb_build_object('ok', true, 'corporation', v_corp_name, 'tasks_cancelled', v_del + v_stp, 'tasks_in_progress_cancelled', v_inprog_n,
    'tasks_deleted', v_del, 'steps_removed', v_stp, 'signatures_cancelled', v_sign, 'sign_cancelled', v_sign, 'signatures_kept', v_kept, 'sign_kept', v_kept, 'finalized_removed', true,
    'paid_reset', v_paid, 'mf_registered', v_mf);
end;
$function$;
revoke all on function public.hq_cancel_payroll_tasks(text, uuid, text, boolean) from public, anon;
grant execute on function public.hq_cancel_payroll_tasks(text, uuid, text, boolean) to authenticated;

-- ③ 確定状態の読み取り（invoices.html の給料確定ボタンの表示用・担当C。権限=確定ボタンと同じ）
--   payroll_finalized_status(p_year_month text, p_corp_id uuid) → {finalized, finalized_at, finalized_by_name, task_count, last_cancelled_at}
--   task_count = 確定が紐づけた本部タスク（links）のうち、まだ生きているもの。finalized_by_name は過去月のbackfill行ではnull
create or replace function public.payroll_finalized_status(p_year_month text, p_corp_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_caller users%rowtype; v_fin payroll_finalized%rowtype; v_name text; v_tasks int; v_last timestamptz;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ')) then
    raise exception '権限がありません（マスター・本部・社長のみ）';
  end if;
  select * into v_fin from payroll_finalized where year_month = p_year_month and corporation_id = p_corp_id;
  if v_fin.finalized_by is not null then select name into v_name from users where id = v_fin.finalized_by; end if;
  select count(*) into v_tasks from payroll_task_links l join hq_tasks t on t.id = l.task_id and t.deleted_at is null
   where l.year_month = p_year_month and l.corporation_id = p_corp_id;
  select max(cancelled_at) into v_last from payroll_finalize_cancellations where year_month = p_year_month and corporation_id = p_corp_id;
  return jsonb_build_object('finalized', v_fin.year_month is not null, 'finalized_at', v_fin.finalized_at,
    'finalized_by_name', v_name, 'task_count', v_tasks, 'last_cancelled_at', v_last);
end;
$function$;
revoke all on function public.payroll_finalized_status(text, uuid) from public, anon;
grant execute on function public.payroll_finalized_status(text, uuid) to authenticated;


-- ③④ テスト
create function pg_temp.call_as(p_sql text, p_uid uuid, p_role text default 'authenticated') returns jsonb language plpgsql as $h$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', p_role)::text, true);
  execute 'set local role ' || p_role;
  execute p_sql into v;
  execute 'reset role';
  return v;
end $h$;
create function pg_temp.expect_err(p_sql text, p_pat text, p_uid uuid, p_role text default 'authenticated') returns void language plpgsql as $h$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', p_role)::text, true);
  execute 'set local role ' || p_role;
  begin
    execute p_sql;
  exception when others then
    execute 'reset role';
    if sqlerrm like p_pat or sqlstate = p_pat then return; end if;
    raise exception 'エラーの内容が想定と違います: [%] %', sqlstate, sqlerrm;
  end;
  execute 'reset role';
  raise exception '拒否されるはずが成功しました: %', p_sql;
end $h$;

do $t$
declare
  ym constant text := '2099-01';
  v_master uuid; v_tencho uuid; v_u1 uuid; v_u2 uuid; v_store uuid; v_corp uuid; v_corp2 uuid; v_cname text;
  v_contract text; v_contract2 text; v_tenant text; v_tmpl uuid;
  v_tc uuid; v_sc uuid; v_tt uuid; v_st uuid; v_tc2 uuid; v_sc2 uuid; r jsonb; n int; q text;
begin
  select id into v_master from users where is_master and is_active limit 1;
  select id into v_tencho from users where role = 'TENCHO' and is_active and not coalesce(is_master,false) limit 1;
  select u.id, (select us.store_id from user_stores us where us.user_id = u.id limit 1) into v_u1, v_store
    from users u where u.is_active and exists (select 1 from user_stores us where us.user_id = u.id) order by u.id limit 1;
  select u.id into v_u2 from users u where u.is_active and u.id <> v_u1 and exists (select 1 from user_stores us where us.user_id = u.id) order by u.id limit 1;
  select sc.corporation_id, sc.contract_id, case sc.corporation_hint when 'toho' then 'default' else sc.corporation_hint end into v_corp, v_contract, v_tenant from smaregi_contracts sc where sc.is_default;
  select sc.corporation_id, sc.contract_id into v_corp2, v_contract2 from smaregi_contracts sc where not sc.is_default and sc.is_active and sc.corporation_id is not null limit 1;
  select name into v_cname from corporations where id = v_corp;
  select id into v_tmpl from hq_task_templates limit 1;
  assert v_master is not null and v_u1 is not null and v_u2 is not null and v_corp is not null and v_tmpl is not null, 'テストの前提データ（マスター・従業員2名・既定契約・テンプレ）が見つかりません';
  assert not exists (select 1 from payroll_finalized where year_month = ym) and not exists (select 1 from payroll_task_links where year_month = ym)
     and not exists (select 1 from sf_cash_handoff_signatures where year_month = ym), '2099-01 に既にデータがあります（未使用月のはず）';

  -- ---- 権限・入力チェック（データ作成前） ----
  r := pg_temp.call_as(format('select public.hq_cancel_payroll_preview(%L, %L::uuid)', ym, v_corp), v_master);
  assert (r->>'finalized')::boolean = false and (r->>'tasks')::int = 0, 'T1 未確定の月×法人: finalized=false・tasks=0';
  perform pg_temp.expect_err(format('select public.hq_cancel_payroll_tasks(%L, %L::uuid, %L, true)', ym, v_corp, 'テスト'), '%給料確定されていません%', v_master);
  if v_tencho is not null then
    perform pg_temp.expect_err(format('select public.hq_cancel_payroll_preview(%L, %L::uuid)', ym, v_corp), '%権限がありません%', v_tencho);
    perform pg_temp.expect_err(format('select public.hq_cancel_payroll_tasks(%L, %L::uuid, %L, true)', ym, v_corp, 'テスト'), '%権限がありません%', v_tencho);
  end if;
  perform pg_temp.expect_err(format('select public.hq_cancel_payroll_preview(%L, %L::uuid)', ym, v_corp), '42501', v_master, 'anon');
  perform pg_temp.expect_err(format('select public.hq_cancel_payroll_tasks(%L, %L::uuid, %L, true)', ym, v_corp, 'テスト'), '42501', v_master, 'anon');
  perform pg_temp.expect_err(format('select public.hq_cancel_payroll_tasks(%L, %L::uuid, %L, true)', ym, v_corp, ''), '%理由%', v_master);
  perform pg_temp.expect_err(format('select public.hq_cancel_payroll_tasks(%L, %L::uuid, %L, true)', ym, v_corp, repeat('あ', 201)), '%理由%', v_master);

  -- ---- テストデータ（2099-01・トーホー側＋別契約の行） ----
  insert into payroll_finalized(year_month, corporation_id, finalized_by) values (ym, v_corp, v_master);
  if v_corp2 is not null then insert into payroll_finalized(year_month, corporation_id, finalized_by) values (ym, v_corp2, v_master); end if;
  -- 確定が新規に作った現金手渡しタスク（進行中: 工程1つ完了・チェック1つ済み）
  insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by, status)
  values ('TEST 現金手渡し', v_cname, 'once', current_date, current_date, '', '給料確定ボタンにより自動発行（テスト）', 'all', v_master, 'doing') returning id into v_tc;
  insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind, completed_at) values (v_tc, '手渡し完了を確認', array[]::uuid[], current_date, 10, 'step', now()) returning id into v_sc;
  insert into hq_step_checklist_items(step_id, title, sort_order, checked_at) values (v_sc, 'A', 10, now()), (v_sc, 'B', 20, null);
  -- テンプレ由来の既存タスクに確認工程を足したもの（足した工程のチェックは未）
  insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by, template_id)
  values ('TEST 振込', v_cname, 'once', current_date, current_date, '', 'テンプレ由来', 'all', v_master, v_tmpl) returning id into v_tt;
  insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind) values (v_tt, '元の工程', array[]::uuid[], current_date, 10, 'step');
  insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind) values (v_tt, '振込対象者の確認（給料確定リスト）', array[]::uuid[], current_date, 20, 'step') returning id into v_st;
  insert into hq_step_checklist_items(step_id, title, sort_order) values (v_st, 'A', 10);
  insert into payroll_task_links(year_month, kind, task_id, step_id, corporation_id) values (ym, 'cash', v_tc, v_sc, v_corp), (ym, 'transfer', v_tt, v_st, v_corp);
  -- サイン: u1=完了（引き出し済み・写真パスあり）、u2=渡した側のみ、別契約のu1=完了（触られてはいけない）
  insert into sf_cash_handoff_signatures(user_id, year_month, store_id, amount, contract_id, payer_id, payer_checked_at, payer_signature_path, receiver_checked_at, receiver_signature_path, completed_at, withdrawn_at)
  values (v_u1, ym, v_store, 1000, v_contract, v_master, now(), 'test/p.png', now(), 'test/r.png', now(), now());
  insert into sf_cash_handoff_signatures(user_id, year_month, store_id, amount, contract_id, payer_id, payer_checked_at) values (v_u2, ym, v_store, 2000, v_contract, v_master, now());
  if v_contract2 is not null then
    insert into sf_cash_handoff_signatures(user_id, year_month, store_id, amount, contract_id, payer_id, payer_checked_at, receiver_checked_at, completed_at)
    values (v_u1, ym, v_store, 3000, v_contract2, v_master, now(), now(), now());
  end if;
  -- 給与仕訳: u1 は振込完了印あり・MF登録済み
  insert into payroll_journal_records(user_id, year_month, tenant_id, paid_at, mf_journal_id) values (v_u1, ym, v_tenant, now(), 'TEST-MF');

  -- ---- preview ----
  r := pg_temp.call_as(format('select public.hq_cancel_payroll_preview(%L, %L::uuid)', ym, v_corp), v_master);
  assert (r->>'finalized')::boolean and (r->>'tasks')::int = 2 and (r->>'tasks_in_progress')::int = 1 and (r->>'tasks_delete')::int = 1 and (r->>'steps_remove')::int = 1, 'T2 preview(タスク): 2件・進行中1・削除1・工程取り外し1 → '||r::text;
  assert (r->>'sign_people')::int = 2 and (r->>'sign_completed')::int = 1 and jsonb_array_length(r->'signed') = 2 and (r->>'paid_marked')::int = 1 and (r->>'mf_registered')::int = 1, 'T3 preview(サイン・仕訳) → '||r::text;

  r := pg_temp.call_as(format('select public.payroll_finalized_status(%L, %L::uuid)', ym, v_corp), v_master);
  assert (r->>'finalized')::boolean and (r->>'task_count')::int = 2 and r->>'finalized_by_name' is not null and r->'last_cancelled_at' = 'null'::jsonb, 'T2b 確定状態(確定済み): finalized・task_count=2・確定者名あり → '||r::text;
  perform pg_temp.expect_err(format('select public.payroll_finalized_status(%L, %L::uuid)', ym, v_corp), '42501', v_master, 'anon');
  if v_tencho is not null then perform pg_temp.expect_err(format('select public.payroll_finalized_status(%L, %L::uuid)', ym, v_corp), '%権限がありません%', v_tencho); end if;
  -- ---- 原子性: 最後のINSERTで失敗させ、全部戻ること ----
  alter table payroll_finalize_cancellations add constraint t_fail check (false) not valid;
  perform pg_temp.expect_err(format('select public.hq_cancel_payroll_tasks(%L, %L::uuid, %L, true)', ym, v_corp, 'テスト'), '%t_fail%', v_master);
  alter table payroll_finalize_cancellations drop constraint t_fail;
  assert (select deleted_at is null from hq_tasks where id = v_tc) and exists (select 1 from hq_task_steps where id = v_st)
     and exists (select 1 from payroll_task_links where year_month = ym and corporation_id = v_corp) and exists (select 1 from payroll_finalized where year_month = ym and corporation_id = v_corp)
     and (select payer_checked_at is not null from sf_cash_handoff_signatures where user_id = v_u1 and year_month = ym and contract_id = v_contract)
     and (select paid_at is not null from payroll_journal_records where user_id = v_u1 and year_month = ym), 'T4 途中失敗で全て元に戻る（原子性）';

  -- ---- 実行A: サインは残す ----
  r := pg_temp.call_as(format('select public.hq_cancel_payroll_tasks(%L, %L::uuid, %L, false)', ym, v_corp, 'テスト残す'), v_master);
  assert (r->>'tasks_cancelled')::int = 2 and (r->>'tasks_in_progress_cancelled')::int = 1 and (r->>'signatures_cancelled')::int = 0 and (r->>'sign_kept')::int = 2 and (r->>'finalized_removed')::boolean, 'T5 戻り値(残す) → '||r::text;
  assert (select deleted_at is not null from hq_tasks where id = v_tc) and (select deleted_at is null from hq_tasks where id = v_tt), 'T6 新規作成タスクは論理削除・テンプレ由来の本体は残る';
  assert not exists (select 1 from hq_task_steps where id = v_st) and exists (select 1 from hq_task_steps where task_id = v_tt and title = '元の工程'), 'T7 足した工程だけ外れる（二重作成の土台: 再確定で足し直せる）';
  assert not exists (select 1 from payroll_task_links where year_month = ym and corporation_id = v_corp) and not exists (select 1 from payroll_finalized where year_month = ym and corporation_id = v_corp), 'T8 links・確定の印が消える';
  assert (select count(*) from sf_cash_handoff_signatures where year_month = ym and payer_checked_at is not null) >= 2 and (select paid_at is not null from payroll_journal_records where user_id = v_u1 and year_month = ym)
     and not exists (select 1 from sf_cash_handoff_cancellations where year_month = ym), 'T9 サインと振込完了印は残る・サイン取消履歴は作られない';
  assert (select cancel_signatures = false and signatures_kept = 2 from payroll_finalize_cancellations where year_month = ym order by cancelled_at desc limit 1), 'T10 取消履歴に「残した」が記録される';
  assert v_corp2 is null or exists (select 1 from payroll_finalized where year_month = ym and corporation_id = v_corp2), 'T11 別法人の確定の印は触れない';

  r := pg_temp.call_as(format('select public.payroll_finalized_status(%L, %L::uuid)', ym, v_corp), v_master);
  assert not (r->>'finalized')::boolean and (r->>'task_count')::int = 0 and r->>'last_cancelled_at' is not null, 'T11b 確定状態(取消後): finalized=false・task_count=0・取消日時あり → '||r::text;

  -- ---- 実行B: サインも取り消す（再確定した状態を作り直す） ----
  insert into payroll_finalized(year_month, corporation_id, finalized_by) values (ym, v_corp, v_master);
  insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by) values ('TEST 現金手渡し2', v_cname, 'once', current_date, current_date, '', '給料確定ボタンにより自動発行（テスト）', 'all', v_master) returning id into v_tc2;
  insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind) values (v_tc2, '手渡し完了を確認', array[]::uuid[], current_date, 10, 'step') returning id into v_sc2;
  insert into payroll_task_links(year_month, kind, task_id, step_id, corporation_id) values (ym, 'cash', v_tc2, v_sc2, v_corp);
  r := pg_temp.call_as(format('select public.hq_cancel_payroll_tasks(%L, %L::uuid, %L, true)', ym, v_corp, 'テスト取消'), v_master);
  assert (r->>'tasks_cancelled')::int = 1 and (r->>'tasks_in_progress_cancelled')::int = 0 and (r->>'signatures_cancelled')::int = 2 and (r->>'paid_reset')::int = 1 and (r->>'mf_registered')::int = 1, 'T12 戻り値(取り消す) → '||r::text;
  assert (select deleted_at is not null from hq_tasks where id = v_tc2), 'T13 未着手タスクも論理削除';
  assert not exists (select 1 from sf_cash_handoff_signatures where year_month = ym and contract_id = v_contract and (payer_checked_at is not null or receiver_checked_at is not null or completed_at is not null or withdrawn_at is not null)), 'T14 トーホー契約のサインは全てリセット';
  assert (select count(*) from sf_cash_handoff_cancellations where year_month = ym and reason like '給料確定の取消: %') = 2
     and (select archived_paths->>'orig_payer_signature' = 'test/p.png' from sf_cash_handoff_cancellations where year_month = ym and user_id = v_u1), 'T15 サイン取消履歴2件・元の画像パスを保存';
  assert (select paid_at is null from payroll_journal_records where user_id = v_u1 and year_month = ym), 'T16 振込完了印が戻る（金額・mf_*列は触れない）';
  assert (select mf_journal_id = 'TEST-MF' from payroll_journal_records where user_id = v_u1 and year_month = ym), 'T17 MF登録情報は消さない';
  assert v_contract2 is null or (select completed_at is not null from sf_cash_handoff_signatures where user_id = v_u1 and year_month = ym and contract_id = v_contract2), 'T18 別契約（別法人）のサインは触れない';
  assert coalesce(current_setting('test.last_notify', true), '') like '%2099-01%' and current_setting('test.last_notify', true) like '%MF%', 'T19 通知文に月・MF登録済みの警告が入る';
  assert (select count(*) from payroll_finalize_cancellations where year_month = ym) = 2, 'T20 確定取消履歴は2件';
  raise notice 'U-27 tests: 全て合格';
end
$t$;

rollback;

-- ⑤ 事後確認（全部 0 / false ならOK。関数も残っていない）
select (select count(*) from payroll_finalized where year_month = '2099-01') as 確定の印,
       (select count(*) from payroll_task_links where year_month = '2099-01') as links,
       (select count(*) from sf_cash_handoff_signatures where year_month = '2099-01') as サイン,
       (select count(*) from hq_tasks where title like 'TEST %') as テストタスク,
       (select count(*) from pg_proc where proname in ('hq_cancel_payroll_tasks','hq_cancel_payroll_preview','payroll_finalized_status')) as U27関数が残っているか,
       (select prosrc like '%test.last_notify%' from pg_proc where proname = 'notify_lark' and pronamespace = 'public'::regnamespace) as 通知関数が差し替えのまま;
