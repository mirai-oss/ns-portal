-- ============================================================
-- 2026-10-17 担当B（nippo）— 退職申請 v6: 種別「移籍（別法人へ）」「兼務追加」＋所属の一致状況
-- 指示書_黒霧屋運営変更_2026-11-01_準備_2026-10-17.md §4・§9・§10／設計メモ_スマレジ複数契約対応 §6・§11
-- 【状態】事前報告（ユーザー確認待ち・未適用）。前提: 退職申請v1〜v5適用済み＋担当D Phase1（smaregi_contracts／employee_smaregi_links）適用済み
--
-- 【理由】2026-11-01に黒霧屋 新横浜の運営がトーホー→LiveGateへ変わる。①移籍（トーホー退職→LiveGate入社）と
--   ②兼務追加（トーホー在籍のままLiveGate追加）を、退職申請・承認と同じ画面・同じ記録（hr_change_requests）で扱う。
--   アカウント・ログインは止めない（退職ではない）。スマレジへの反映は画面から smaregi-sync（契約指定）を呼ぶ。
--   あわせて、従業員の所属店舗（管理システム）とスマレジの所属事業所の一致状況を画面で見るためのRPCを足す。
-- 【現構造】hr_change_requests.kind は 'retirement' のみ。承認RPC hr_approve_retirement は種別を見ない
--   （＝移籍の申請をこれで承認すると退職になってしまうため、種別チェックを足す）。所属の比較用の表
--   （smaregi_staff_stores_snapshot・staff_store_sync・smaregi_store_ignore）は担当Dの表で、画面（authenticated）からは読めない
-- 【変更】
--   ① hr_change_requests: kind に 'transfer'(移籍)・'concurrent'(兼務追加) を許可／列 from_contract_id・to_contract_id 追加／
--      承認待ちの重複防止（同じ人・同じ種別の承認待ちは1件）
--   ② hr_approve_retirement・hr_cancel_retirement: 退職申請以外には使えないようにする（種別チェック追加。他は同じ）
--   ③ 新RPC hr_request_contract_change（申請。店長・チーム長・本部・社長・マスター）／hr_approve_contract_change（承認＝記録のみ。
--      アカウント・退職日は触らない）／hr_direct_contract_change（本部が直接登録＝承認済みの記録を作る。同じ人・種別・移行先で
--      未完了のものがあればそれを返す＝再実行しても二重にならない）
--   ④ 新RPC hr_due_transfer_deactivations／hr_record_transfer_deactivation（service_role専用）: 移籍で旧契約を閉じた翌日に、
--      旧契約のスマレジの打刻をOFFにする毎日処理用（既存のworkflowに足す）
--   ⑤ 新RPC hr_staff_store_status（本部・社長・マスターのみ）: 人×契約の「管理システムの所属」「スマレジの所属（最新の棚卸しスナップショット）」
--      「前回同期（台帳）」を比べた一致状況。画面の「スマレジ所属（契約ごと）」「所属のズレ」一覧が使う
-- 【影響】既存の行・既存の退職申請の動きは変えない（種別チェックの追加のみ）。担当Dの表は読むだけ（書かない）
-- 【migration】本ファイル（冪等）
-- 【rollback】drop function if exists public.hr_request_contract_change(uuid,uuid,text,text,date,text);
--   drop function if exists public.hr_approve_contract_change(uuid); drop function if exists public.hr_direct_contract_change(uuid,text,text,date,text);
--   drop function if exists public.hr_due_transfer_deactivations(); drop function if exists public.hr_record_transfer_deactivation(uuid,boolean,jsonb);
--   drop function if exists public.hr_staff_store_status(uuid,boolean); drop index if exists hr_change_requests_one_pending_change;
--   hr_approve_retirement／hr_cancel_retirement は 2026-10-03_hr_change_requests.sql／_v2.sql の定義へ戻す。列・checkは残しても無害
-- ============================================================

-- ① 種別・列・重複防止
alter table hr_change_requests add column if not exists from_contract_id text; -- 移籍元のスマレジ契約ID（移籍のみ）
alter table hr_change_requests add column if not exists to_contract_id text;   -- 移行先のスマレジ契約ID
do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.hr_change_requests'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%retirement%' and pg_get_constraintdef(oid) like '%kind%' loop
    execute format('alter table hr_change_requests drop constraint %I', c);
  end loop;
  alter table hr_change_requests add constraint hr_change_requests_kind_check
    check (kind in ('retirement','transfer','concurrent'));
end $$;
create unique index if not exists hr_change_requests_one_pending_change
  on hr_change_requests(user_id, kind) where status = 'pending' and kind in ('transfer','concurrent');

-- ② 退職専用のRPCに種別チェック
create or replace function public.hr_approve_retirement(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r hr_change_requests%rowtype; v_tdate date; v_active boolean;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  select * into r from hr_change_requests where id = p_request for update; -- 承認の連打・二重承認防止
  if r.id is null then raise exception '申請が見つかりません'; end if;
  if r.kind <> 'retirement' then raise exception 'この申請は退職申請ではありません（%）。種別に合った承認操作を使ってください', r.kind; end if;
  if r.status <> 'pending' then raise exception 'この申請は既に処理済みです（%）', r.status; end if;
  -- 承認時点の最新状態を再取得して検証（異動・退職済み・別経路での退職日登録）
  select is_active into v_active from users where id = r.user_id;
  if v_active is distinct from true then raise exception '対象の従業員は既に退職済み（無効）です'; end if;
  if not exists(select 1 from user_stores where user_id = r.user_id and store_id = r.store_id) then
    raise exception '申請後に所属店舗が変わっています。内容を確認して、必要なら申請をやり直してください';
  end if;
  select termination_date into v_tdate from employee_profiles where user_id = r.user_id;
  if v_tdate is not null then raise exception '既に退職日が登録されています（%）', v_tdate; end if;
  -- 既存RPC（§6で「退職日の翌日に停止／過去日なら即停止」へ改修）。退職日は申請の値をそのまま渡す＝一致を保証（要望7章）
  perform set_employee_termination(r.user_id, r.effective_date);
  update hr_change_requests set status = 'approved', approved_by = auth.uid(), approved_at = now(), updated_at = now() where id = r.id;
  select is_active into v_active from users where id = r.user_id;
  return jsonb_build_object('ok', true, 'request_id', r.id, 'user_id', r.user_id,
    'effective_date', r.effective_date, 'deactivated_now', not coalesce(v_active, true));
end;
$function$;
create or replace function public.hr_cancel_retirement(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r hr_change_requests%rowtype; v_tdate date;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  select * into r from hr_change_requests where id = p_request for update;
  if r.id is null then raise exception '申請が見つかりません'; end if;
  if r.kind <> 'retirement' then raise exception 'この申請は退職申請ではありません（%）', r.kind; end if;
  if r.status <> 'approved' then raise exception '承認済みの申請だけ取り消せます（現在: %）', r.status; end if;
  select termination_date into v_tdate from employee_profiles where user_id = r.user_id;
  if v_tdate is distinct from r.effective_date then
    raise exception '退職日が申請と異なります（現在の退職日: %）。従業員編集の退職日カードで確認してください', coalesce(v_tdate::text, '未登録');
  end if;
  perform set_employee_termination(r.user_id, null); -- 復職（この中で該当申請が取り消し済みになる）
  return jsonb_build_object('ok', true, 'request_id', r.id, 'user_id', r.user_id);
end;
$function$;

-- ③ 申請（移籍・兼務追加）。p_to_contract=移行先のスマレジ契約ID。移籍は移籍元を自動判定（その人の有効なリンクのうち移行先以外）
create or replace function public.hr_request_contract_change(p_store uuid, p_user uuid, p_kind text, p_to_contract text, p_date date, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date; v_id uuid; v_from text;
begin
  if p_kind not in ('transfer','concurrent') then raise exception '種別は移籍(transfer)か兼務追加(concurrent)を指定してください'; end if;
  if not hr_can_act_store(p_store) then raise exception '権限がありません（この店舗の申請はできません）'; end if;
  if p_date is null or p_date < v_today - 30 or p_date > v_today + 366 then raise exception '開始日は30日前から1年先までの日付を指定してください'; end if;
  if not exists(select 1 from user_stores where user_id = p_user and store_id = p_store) then raise exception 'この店舗に所属していない従業員です'; end if;
  if not exists(select 1 from users where id = p_user and is_active) then raise exception '既に退職済み（無効）の従業員です'; end if;
  if not exists(select 1 from smaregi_contracts where contract_id = p_to_contract and is_active) then raise exception '移行先のスマレジ契約が見つかりません'; end if;
  if exists(select 1 from employee_smaregi_links where user_id = p_user and contract_id = p_to_contract and effective_to is null) then
    raise exception 'この従業員は既に移行先の契約に登録されています';
  end if;
  if p_kind = 'transfer' then
    select contract_id into v_from from employee_smaregi_links
     where user_id = p_user and effective_to is null and contract_id <> p_to_contract
     order by is_primary desc, created_at limit 1;
    if v_from is null then raise exception '移籍元のスマレジ連携が見つかりません（先にスマレジ連携を確認してください）'; end if;
  end if;
  begin
    insert into hr_change_requests(kind, store_id, user_id, effective_date, requested_by, from_contract_id, to_contract_id, note)
    values (p_kind, p_store, p_user, p_date, auth.uid(), v_from, p_to_contract, nullif(btrim(coalesce(p_note,'')), '')) returning id into v_id;
  exception when unique_violation then
    raise exception 'この従業員には同じ種別の承認待ちの申請が既にあります';
  end;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$function$;
revoke all on function public.hr_request_contract_change(uuid, uuid, text, text, date, text) from public, anon;
grant execute on function public.hr_request_contract_change(uuid, uuid, text, text, date, text) to authenticated;

-- 承認（記録のみ。アカウント・退職日・所属は変えない。スマレジへの反映は画面から smaregi-sync を呼ぶ）
create or replace function public.hr_approve_contract_change(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r hr_change_requests%rowtype;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  select * into r from hr_change_requests where id = p_request for update;
  if r.id is null then raise exception '申請が見つかりません'; end if;
  if r.kind not in ('transfer','concurrent') then raise exception 'この申請は移籍・兼務追加ではありません（%）', r.kind; end if;
  if r.status <> 'pending' then raise exception 'この申請は既に処理済みです（%）', r.status; end if;
  if not exists(select 1 from users where id = r.user_id and is_active) then raise exception '対象の従業員は既に退職済み（無効）です'; end if;
  if exists(select 1 from employee_smaregi_links where user_id = r.user_id and contract_id = r.to_contract_id and effective_to is null) then
    raise exception 'この従業員は既に移行先の契約に登録されています';
  end if;
  update hr_change_requests set status = 'approved', approved_by = auth.uid(), approved_at = now(), updated_at = now() where id = r.id;
  return jsonb_build_object('ok', true, 'request_id', r.id, 'kind', r.kind, 'user_id', r.user_id,
    'effective_date', r.effective_date, 'from_contract_id', r.from_contract_id, 'to_contract_id', r.to_contract_id);
end;
$function$;
revoke all on function public.hr_approve_contract_change(uuid) from public, anon;
grant execute on function public.hr_approve_contract_change(uuid) to authenticated;

-- 本部が直接登録（承認済みの記録を作る）。同じ人・種別・移行先で未完了（sync_statusがsyncedでない）の承認済みがあればそれを返す
create or replace function public.hr_direct_contract_change(p_user uuid, p_kind text, p_to_contract text, p_date date, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date; v_id uuid; v_from text; v_store uuid; v_exist hr_change_requests%rowtype;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  if p_kind not in ('transfer','concurrent') then raise exception '種別は移籍(transfer)か兼務追加(concurrent)を指定してください'; end if;
  if p_date is null or p_date < v_today - 30 or p_date > v_today + 366 then raise exception '開始日は30日前から1年先までの日付を指定してください'; end if;
  if not exists(select 1 from users where id = p_user and is_active) then raise exception '既に退職済み（無効）の従業員です'; end if;
  if not exists(select 1 from smaregi_contracts where contract_id = p_to_contract and is_active) then raise exception '移行先のスマレジ契約が見つかりません'; end if;
  -- 再実行（前回失敗・未完了の承認済み）
  select * into v_exist from hr_change_requests
   where user_id = p_user and kind = p_kind and to_contract_id = p_to_contract and status = 'approved' and sync_status <> 'synced'
   order by created_at desc limit 1;
  if v_exist.id is not null then
    return jsonb_build_object('ok', true, 'id', v_exist.id, 'reused', true, 'from_contract_id', v_exist.from_contract_id, 'effective_date', v_exist.effective_date);
  end if;
  if exists(select 1 from employee_smaregi_links where user_id = p_user and contract_id = p_to_contract and effective_to is null) then
    raise exception 'この従業員は既に移行先の契約に登録されています';
  end if;
  if p_kind = 'transfer' then
    select contract_id into v_from from employee_smaregi_links
     where user_id = p_user and effective_to is null and contract_id <> p_to_contract
     order by is_primary desc, created_at limit 1;
    if v_from is null then raise exception '移籍元のスマレジ連携が見つかりません（先にスマレジ連携を確認してください）'; end if;
  end if;
  select store_id into v_store from user_stores where user_id = p_user order by is_primary desc nulls last limit 1;
  if v_store is null then raise exception '所属店舗が登録されていない従業員です'; end if;
  insert into hr_change_requests(kind, store_id, user_id, effective_date, status, requested_by, approved_by, approved_at, from_contract_id, to_contract_id, note)
  values (p_kind, v_store, p_user, p_date, 'approved', auth.uid(), auth.uid(), now(), v_from, p_to_contract, nullif(btrim(coalesce(p_note,'')), ''))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'reused', false, 'from_contract_id', v_from, 'effective_date', p_date);
end;
$function$;
revoke all on function public.hr_direct_contract_change(uuid, text, text, date, text) from public, anon;
grant execute on function public.hr_direct_contract_change(uuid, text, text, date, text) to authenticated;

-- ④ 移籍の旧契約のスマレジ打刻OFF（毎日・service_role専用）: 旧契約の終了日（開始日の前日）を過ぎた承認済みの移籍で、
--   旧契約の終了反映(terminate)に成功しているが打刻OFFがまだのもの
create or replace function public.hr_due_transfer_deactivations()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('request_id', r.id, 'user_id', r.user_id, 'contract_id', r.from_contract_id))
      from hr_change_requests r
     where r.kind = 'transfer' and r.status = 'approved' and r.from_contract_id is not null
       and r.effective_date - 1 < v_today
       and coalesce(r.sync_result->'terminate'->>'ok', 'false') = 'true'
       and coalesce(r.sync_result->>'old_deactivated', 'false') <> 'true'
  ), '[]'::jsonb));
end;
$function$;
revoke all on function public.hr_due_transfer_deactivations() from public, anon, authenticated;
grant execute on function public.hr_due_transfer_deactivations() to service_role;

create or replace function public.hr_record_transfer_deactivation(p_request uuid, p_ok boolean, p_result jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update hr_change_requests
     set sync_result = coalesce(sync_result, '{}'::jsonb) || jsonb_build_object('old_deactivated', p_ok, 'old_deactivate_result', coalesce(p_result, '{}'::jsonb)),
         sync_status = case when p_ok then sync_status else 'error' end,
         updated_at = now()
   where id = p_request and kind = 'transfer';
  return jsonb_build_object('ok', true);
end;
$function$;
revoke all on function public.hr_record_transfer_deactivation(uuid, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.hr_record_transfer_deactivation(uuid, boolean, jsonb) to service_role;

-- ⑤ 所属の一致状況（人×契約）。管理システム＝user_stores（その契約に対応のある店舗だけ）／スマレジ＝最新スナップショット
--   （担当Dの毎日の棚卸し。除外リストの事業所は無視）／前回同期＝staff_store_sync（台帳）。p_user=null で全員、p_only_diff=true でズレのある人だけ
create or replace function public.hr_staff_store_status(p_user uuid default null, p_only_diff boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_out jsonb; v_today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  with lk as (
    select l.user_id, l.contract_id, l.smaregi_staff_id, c.label, c.corporation_hint, c.is_default
      from employee_smaregi_links l
      join smaregi_contracts c on c.contract_id = l.contract_id and c.is_active
     where (p_user is null or l.user_id = p_user)
       and (l.effective_to is null or l.effective_to >= v_today)
  ),
  mp as (
    select c.contract_id, e.external_store_id::text as sm_store, e.store_id
      from smaregi_contracts c
      join store_external_mappings e
        on e.source_system = 'smaregi_timecard' and coalesce(e.is_active, true)
       and (e.effective_to is null or e.effective_to >= v_today)
       and (e.effective_from is null or e.effective_from <= v_today)
       and ((e.corporation_hint is not null and e.corporation_hint = c.corporation_hint) or (e.corporation_hint is null and c.is_default))
     where c.is_active
  ),
  sm as (
    select lk.user_id, lk.contract_id, s.smaregi_store_id, mp.store_id
      from lk
      join smaregi_staff_stores_snapshot s on s.contract_id = lk.contract_id and s.smaregi_staff_id = lk.smaregi_staff_id
      left join smaregi_store_ignore ig on ig.contract_id = s.contract_id and ig.store_id = s.smaregi_store_id
      left join mp on mp.contract_id = s.contract_id and mp.sm_store = s.smaregi_store_id
     where ig.store_id is null
  ),
  per as (
    select lk.*,
      coalesce((select array_agg(distinct us.store_id) from user_stores us
                 where us.user_id = lk.user_id
                   and exists (select 1 from mp where mp.contract_id = lk.contract_id and mp.store_id = us.store_id)), array[]::uuid[]) as portal_ids,
      coalesce((select array_agg(distinct sm.store_id) from sm
                 where sm.user_id = lk.user_id and sm.contract_id = lk.contract_id and sm.store_id is not null), array[]::uuid[]) as smaregi_ids,
      coalesce((select array_agg(distinct g.store_id) from staff_store_sync g
                 where g.user_id = lk.user_id and g.contract_id = lk.contract_id), array[]::uuid[]) as ledger_ids,
      coalesce((select jsonb_agg(distinct sm.smaregi_store_id) from sm
                 where sm.user_id = lk.user_id and sm.contract_id = lk.contract_id and sm.store_id is null), '[]'::jsonb) as unmapped,
      (select max(fetched_at) from smaregi_staff_stores_snapshot x where x.contract_id = lk.contract_id) as snapshot_at
    from lk
  ),
  rows_ as (
    select per.*, u.name,
      (per.portal_ids <@ per.smaregi_ids and per.smaregi_ids <@ per.portal_ids) as in_sync
      from per join users u on u.id = per.user_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', r.user_id, 'name', r.name, 'contract_id', r.contract_id, 'label', r.label,
      'smaregi_staff_id', r.smaregi_staff_id, 'snapshot_at', r.snapshot_at, 'in_sync', r.in_sync,
      'portal', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name) order by st.sort_order), '[]'::jsonb) from stores st where st.id = any(r.portal_ids)),
      'smaregi', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name) order by st.sort_order), '[]'::jsonb) from stores st where st.id = any(r.smaregi_ids)),
      'only_portal', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name)), '[]'::jsonb) from stores st where st.id = any(r.portal_ids) and not (st.id = any(r.smaregi_ids))),
      'only_smaregi', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name)), '[]'::jsonb) from stores st where st.id = any(r.smaregi_ids) and not (st.id = any(r.portal_ids))),
      'unmapped', r.unmapped,
      'changed_side', case
          when r.in_sync then 'none'
          when r.portal_ids is distinct from r.ledger_ids and r.smaregi_ids is distinct from r.ledger_ids then 'both'
          when r.portal_ids is distinct from r.ledger_ids then 'portal'
          when r.smaregi_ids is distinct from r.ledger_ids then 'smaregi'
          else 'unknown' end
    ) order by r.name), '[]'::jsonb)
    into v_out
    from rows_ r
   where (not p_only_diff) or (not r.in_sync);
  return v_out;
end;
$function$;
revoke all on function public.hr_staff_store_status(uuid, boolean) from public, anon;
grant execute on function public.hr_staff_store_status(uuid, boolean) to authenticated;
