-- =============================================================
-- 2026-11-09 入社登録ワークフロー Phase 1 の切り戻し（データ保全版）
--   方針（ユーザー指示 2026-11-09）: 適用後に作られた入社ワークフロー（onboarding_workflows / onboarding_items）と監査履歴（onboarding_events）は消さない。
--   この SQL がやること: 新しい仕組みを「止める」（トリガー・RPC・ビューを外し、変更した 3 関数を適用前の定義に戻す）。表と行はそのまま残る（本部・社長・マスターは引き続き読める）。
--   やらないこと: 表の drop・行の削除・列の削除。完全に消したいときだけ、最後の「完全削除（任意・別承認）」を使う。その場合も先にアーカイブ表へ写す。
--   使いどころ: 適用後に不具合が出て Phase 1 の DB 側を無効化したいとき。通知だけ止めるなら 2026-11-09_onboarding_switch.sql の「戻し方」で足りる（こちらは不要）。
--   関数の旧定義は supabase/restored/2026-11-09_onboarding_prod_snapshot.sql（適用前に本番から取得）と同じ。
--   実行: python3 scripts/apply_sql.py supabase/2026-11-09_onboarding_phase1_rollback.sql [--dry-run]
-- =============================================================

-- 0) まず新しい仕組みを止める（通知フラグ OFF。EF が残っていても親メッセージは作られない）
update public.app_settings set value = coalesce(value, '{}'::jsonb) || jsonb_build_object('enabled', false, 'legacy_wage_text', true, 'rolled_back_at', now()), updated_at = now() where key = 'onboarding_slack';

-- 1) 本部タスクとの双方向連動（トリガー）を外す
drop trigger if exists trg_onboarding_hq_checklist_sync on public.hq_step_checklist_items;
drop trigger if exists trg_onboarding_hq_step_sync on public.hq_task_steps;
drop function if exists public.onboarding_hq_checklist_sync();
drop function if exists public.onboarding_hq_step_sync();

-- 2) RPC・ビューを外す（表は残す）
drop view if exists public.onboarding_workflow_v;
drop function if exists public.onboarding_set_item(uuid, text, text, jsonb, uuid, text, text);
drop function if exists public.onboarding_start(uuid, text, uuid);

-- 3) 変更した 3 関数を適用前の定義へ（新シグネチャを落として旧定義を作る。nippo の名前付き呼び出しは旧版に解決される）
drop function if exists public.hr_save_wage(uuid, text, integer, uuid, integer, integer, date, uuid);
drop function if exists public.hq_create_onboarding_task(text, text, text, text, date, uuid);
drop function if exists public.onboarding_resolve_actor(uuid);
drop function if exists public.onboarding_is_service();

CREATE OR REPLACE FUNCTION public.hire_applicant(p_applicant uuid, p_role text, p_store_ids uuid[] DEFAULT '{}'::uuid[], p_days integer DEFAULT 14)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare a applicants%rowtype; v_token text := encode(extensions.gen_random_bytes(16), 'hex');
begin
  if not has_feature(auth.uid(),'recruit') then raise exception '権限がありません（採用担当のみ）'; end if;
  if p_role not in ('AL','SHAIN','TENCHO','TEAM','HQ') then raise exception '不正な役職です'; end if;
  select * into a from applicants where id = p_applicant for update;
  if not found then raise exception '応募者が見つかりません'; end if;
  insert into invitations (token, role, store_ids, note, created_by, expires_at, applicant_id, applicant_name, applicant_phone)
  values (v_token, p_role, p_store_ids, '応募者: ' || a.name, auth.uid(),
          now() + make_interval(days => greatest(coalesce(p_days,14),1)), a.id, a.name, a.phone);
  update applicants set status = 'hired', status_changed_at = now(), updated_at = now(), invite_token = v_token
    where id = a.id;
  return v_token;
end $function$;

CREATE OR REPLACE FUNCTION public.hq_create_onboarding_task(p_name text, p_email text DEFAULT NULL::text, p_corp text DEFAULT 'トーホー'::text, p_business text DEFAULT NULL::text, p_target_date date DEFAULT CURRENT_DATE)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_task_id uuid;
  v_assignee uuid;
  v_step3_id uuid;
  v_corp text;
  v_due date;
begin
  if auth.uid() is null or not exists(select 1 from users u where u.id = auth.uid() and u.is_active) then
    raise exception '認証が必要です';
  end if;
  if p_name is null or trim(p_name) = '' then
    raise exception '氏名が必要です';
  end if;

  v_due := p_target_date + 1;

  -- 所属事業所（店舗名）から実際の法人を自動判定（見つからなければp_corpへフォールバック）
  select c.name into v_corp
    from stores s join corporations c on c.id = s.corporation_id
    where s.name = p_business and s.is_active
    limit 1;
  if v_corp is null then
    v_corp := coalesce(p_corp, 'トーホー');
  end if;

  select id into v_assignee from users where name = '青山純' and is_active limit 1;
  if v_assignee is null then
    select id into v_assignee from users where name = '齋藤　隆治' and is_active limit 1;
  end if;

  insert into hq_tasks (title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
  values (
    '入社登録（' || p_name || 'さん）', v_corp, 'once', p_target_date, v_due, '',
    '新入社員: ' || p_name || 'さん' || E'\n' ||
    'メールアドレス: ' || coalesce(p_email, '（未設定）') || E'\n' ||
    '所属事業所: ' || coalesce(p_business, '（未設定）'),
    'all', auth.uid()
  ) returning id into v_task_id;

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date)
  values (v_task_id, 'メールアドレスを登録（' || coalesce(p_email, '未設定') || '）', v_assignee, 10, 'step', v_due);

  -- 2026-10-17: 工程「所属事業所を入力」は廃止（管理システムの所属店舗をスマレジへ自動同期するため。ユーザー指示）。sort_order=20は欠番のまま

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date)
  values (v_task_id, '給与・明細設定を入力', v_assignee, 30, 'step', v_due)
  returning id into v_step3_id;
  insert into hq_step_checklist_items(step_id, title, sort_order) values
    (v_step3_id, '時給', 10),
    (v_step3_id, '交通費', 20),
    (v_step3_id, '源泉所得税の適用', 30),
    (v_step3_id, '個別Web給与明細表示設定', 40);

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, action_kind, action_payload, due_date)
  values (v_task_id, 'LINEで登録案内を送る', v_assignee, 40, 'step', 'onboarding_line_guide',
          jsonb_build_object('name', p_name, 'email', p_email), v_due);

  insert into hq_task_activity(task_id, actor_id, kind, detail)
  values (v_task_id, auth.uid(), 'create', '入社登録により自動作成（' || p_name || 'さん）');

  return v_task_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.hr_save_wage(p_user uuid, p_contract text, p_division integer, p_store uuid, p_wage integer, p_holiday integer, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  if p_division not in (0, 2) then raise exception '給与形態は時給(0)か月給(2)を指定してください'; end if;
  if not exists(select 1 from users where id = p_user) then raise exception '対象の従業員が見つかりません'; end if;
  if not exists(select 1 from smaregi_contracts where contract_id = p_contract and is_active) then raise exception 'スマレジの契約が見つかりません'; end if;
  if p_wage is null or p_wage < 0 or p_wage > 100000000 then raise exception '金額が不正です'; end if;
  if p_date is null or p_date < date '2000-01-01' then raise exception '適用開始日を指定してください'; end if;
  if p_division = 2 then
    if p_store is not null then raise exception '月給は店舗を指定できません'; end if;
    if extract(day from p_date) <> 1 then raise exception '月給の適用開始日は月初日（1日）にしてください'; end if;
    p_holiday := null;
  end if;
  if p_division = 0 and p_wage > 100000 then raise exception '時給が大きすぎます（%円）。月給は「月給」で入力してください', p_wage; end if;
  if p_store is not null and not exists(select 1 from stores where id = p_store) then raise exception '店舗が見つかりません'; end if;
  insert into employee_wage_settings(user_id, contract_id, division, store_id, wage, holiday_wage, effective_date, created_by)
  values (p_user, p_contract, p_division, p_store, p_wage, p_holiday, p_date, auth.uid())
  on conflict (user_id, contract_id, division, coalesce(store_id, '00000000-0000-0000-0000-000000000000'::uuid), effective_date)
  do update set wage = excluded.wage, holiday_wage = excluded.holiday_wage, sync_status = 'pending', sync_error = null, updated_at = now()
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$function$;

grant execute on function public.hr_save_wage(uuid, text, integer, uuid, integer, integer, date) to authenticated, service_role;
revoke execute on function public.hr_save_wage(uuid, text, integer, uuid, integer, integer, date) from public, anon;
grant execute on function public.hq_create_onboarding_task(text, text, text, text, date) to authenticated, service_role;

-- 4) 残すもの（意図的）: 表 onboarding_workflows / onboarding_items / onboarding_events とその行・RLS（読み＝本部・社長・マスター）、
--    列 applicants.hired_at / hr_wage_requests.workflow_id、設定行 app_settings.onboarding_slack（enabled=false に戻した）。
--    制約 employee_wage_settings_division_check も (0,1,2) のまま残す（日給行があると戻せない・残しても既存の時給/月給の動きは変わらない）。
--    どうしても (0,2) に戻すときは、日給行が 0 件であることを確認してから:
--      alter table public.employee_wage_settings drop constraint if exists employee_wage_settings_division_check;
--      alter table public.employee_wage_settings add constraint employee_wage_settings_division_check check (division in (0, 2));

-- 5) 完全削除（任意・別承認・通常は実行しない）: 先にアーカイブ表へ写してから落とす
-- create schema if not exists archive;
-- create table archive.onboarding_workflows_20261109 as select * from public.onboarding_workflows;
-- create table archive.onboarding_items_20261109     as select * from public.onboarding_items;
-- create table archive.onboarding_events_20261109    as select * from public.onboarding_events;
-- drop table public.onboarding_events; drop table public.onboarding_items; drop table public.onboarding_workflows;

select '切り戻し（データ保全版）を適用しました: 新しい仕組みは停止・表と履歴は残っています' as note;
