-- 2026-10-05 担当A: 申請履歴からの「編集・削除」（スポット人件費の申請／仕入れ移動の現場申請）。社長・本部・マスターのみ。
-- 前提: 2026-10-05_request_history.sql ／ _request_forms.sql 適用済み。
-- 【影響】spot_labor_requestsに列entry_id追加（承認時に記録したスポット人件費の行ID。編集・削除でスプレッドシートの行も合わせるため）／
--   request_log.kindの許可値を2つ追加／RPCを追加・作り直し（spot_request_get・spot_request_decide は戻り列/引数を拡張）。既存の行・挙動は変えない。
-- 【rollback】drop function spot_request_update, spot_request_delete, cost_transfer_request_get, cost_transfer_request_update, cost_transfer_request_delete;
--   spot_request_get/decide は 2026-10-05_request_forms.sql の定義に戻す。

alter table public.spot_labor_requests add column if not exists entry_id text;

alter table public.request_log drop constraint if exists request_log_kind_check;
alter table public.request_log add constraint request_log_kind_check
  check (kind in ('spot_labor', 'cost_transfer_direct', 'spot_labor_edit', 'cost_transfer_edit'));

-- 取得（entry_id付き）
drop function if exists public.spot_request_get(uuid);
create or replace function public.spot_request_get(p_id uuid)
returns table (id uuid, store_name text, work_date date, kind text, amount numeric, headcount int, note text, requester_id uuid, requester_name text, status text, entry_id text)
language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  return query select r.id, r.store_name, r.work_date, r.kind, r.amount, r.headcount, r.note, r.requester_id, r.requester_name, r.status, r.entry_id
               from public.spot_labor_requests r where r.id = p_id;
end;
$$;
revoke all on function public.spot_request_get(uuid) from public, anon;
grant execute on function public.spot_request_get(uuid) to authenticated;

-- 承認/却下（承認時は記録したスポット人件費の行IDも保存）
drop function if exists public.spot_request_decide(uuid, text, text);
create or replace function public.spot_request_decide(p_id uuid, p_decision text, p_reason text, p_entry_id text default null)
returns void language plpgsql security definer set search_path to 'public'
as $$
declare v_name text; v_n int;
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception 'bad decision'; end if;
  select u.name into v_name from public.users u where u.id = auth.uid();
  update public.spot_labor_requests r
     set status = p_decision, approver = v_name, approved_at = now(),
         reject_reason = case when p_decision = 'rejected' then nullif(left(p_reason, 200), '') else null end,
         entry_id = coalesce(nullif(p_entry_id, ''), r.entry_id)
   where r.id = p_id and r.status = 'pending';
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception '既に処理済みか、対象がありません'; end if;
end;
$$;
revoke all on function public.spot_request_decide(uuid, text, text, text) from public, anon;
grant execute on function public.spot_request_decide(uuid, text, text, text) to authenticated;

-- スポット人件費の申請の修正（承認済みでも可。スプレッドシート側はクライアントがGASで合わせる）
create or replace function public.spot_request_update(
  p_id uuid, p_store text, p_date date, p_kind text, p_amount numeric, p_headcount int, p_note text, p_requester_id uuid)
returns void language plpgsql security definer set search_path to 'public'
as $$
declare v_rname text; v_ename text; v_n int;
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  if p_kind not in ('タイミー', 'その他') then raise exception '区分が不正です'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 1000000 then raise exception '金額が不正です'; end if;
  if coalesce(p_store, '') = '' or p_date is null then raise exception '店舗と日付は必須です'; end if;
  select u.name into v_rname from public.users u where u.id = p_requester_id;
  select u.name into v_ename from public.users u where u.id = auth.uid();
  update public.spot_labor_requests r
     set store_name = p_store, work_date = p_date, kind = p_kind, amount = p_amount, headcount = p_headcount, note = nullif(p_note, ''),
         requester_id = coalesce(p_requester_id, r.requester_id), requester_name = coalesce(v_rname, r.requester_name)
   where r.id = p_id;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception '対象がありません'; end if;
  insert into public.request_log (kind, requester_name, requester_id, entered_by, store_name, summary, amount, action, ref_id)
  values ('spot_labor_edit', v_rname, p_requester_id, v_ename, p_store, '申請の修正：' || p_store || '／' || p_date || '／' || p_kind, p_amount, 'update', p_id::text);
end;
$$;
revoke all on function public.spot_request_update(uuid, text, date, text, numeric, int, text, uuid) from public, anon;
grant execute on function public.spot_request_update(uuid, text, date, text, numeric, int, text, uuid) to authenticated;

create or replace function public.spot_request_delete(p_id uuid)
returns void language plpgsql security definer set search_path to 'public'
as $$
declare r public.spot_labor_requests%rowtype; v_ename text;
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  select * into r from public.spot_labor_requests where id = p_id;
  if r.id is null then raise exception '対象がありません'; end if;
  select u.name into v_ename from public.users u where u.id = auth.uid();
  delete from public.spot_labor_requests where id = p_id;
  insert into public.request_log (kind, requester_name, requester_id, entered_by, store_name, summary, amount, action, ref_id)
  values ('spot_labor_edit', r.requester_name, r.requester_id, v_ename, r.store_name, '申請の削除：' || r.store_name || '／' || r.work_date || '／' || r.kind || '（元の状態: ' || r.status || '）', r.amount, 'delete', p_id::text);
end;
$$;
revoke all on function public.spot_request_delete(uuid) from public, anon;
grant execute on function public.spot_request_delete(uuid) to authenticated;

-- 仕入れ移動の現場申請（承認待ちのみ編集可）
create or replace function public.cost_transfer_request_get(p_id uuid)
returns table (id uuid, transfer_date date, from_store text, to_store text, items jsonb, total numeric, note text, requester_id uuid, requester_name text, status text)
language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  return query select r.id, r.transfer_date::date, r.from_store, r.to_store, r.items, r.total::numeric, r.note, r.requester_id, r.requester_name, r.status::text
               from public.cost_transfer_requests r where r.id = p_id;
end;
$$;
revoke all on function public.cost_transfer_request_get(uuid) from public, anon;
grant execute on function public.cost_transfer_request_get(uuid) to authenticated;

create or replace function public.cost_transfer_request_update(
  p_id uuid, p_date date, p_from text, p_to text, p_items jsonb, p_note text, p_requester_id uuid)
returns void language plpgsql security definer set search_path to 'public'
as $$
declare v_status text; v_items jsonb; v_total numeric; v_rname text; v_ename text; v_cnt int;
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  select r.status into v_status from public.cost_transfer_requests r where r.id = p_id;
  if v_status is null then raise exception '対象がありません'; end if;
  if v_status <> 'pending' then raise exception '承認待ちの申請だけ修正できます'; end if;
  if p_from = p_to or coalesce(p_from, '') = '' or coalesce(p_to, '') = '' then raise exception '移動元と移動先は別の店舗を選んでください'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception '商品を1つ以上入れてください'; end if;
  -- 金額は品目マスタの単価×数量でサーバー側で再計算（改ざん防止）
  select jsonb_agg(jsonb_build_object('name', e ->> 'name', 'qty', (e ->> 'qty')::numeric, 'unitPrice', m.unit_price, 'amount', round(m.unit_price * (e ->> 'qty')::numeric))),
         sum(round(m.unit_price * (e ->> 'qty')::numeric)), count(*)
    into v_items, v_total, v_cnt
    from jsonb_array_elements(p_items) e
    join public.cost_transfer_items m on m.name = e ->> 'name' and m.active
   where (e ->> 'qty')::numeric > 0;
  if v_items is null or v_cnt <> jsonb_array_length(p_items) then raise exception '商品または数量が不正です（無効な商品が含まれています）'; end if;
  select u.name into v_rname from public.users u where u.id = p_requester_id;
  select u.name into v_ename from public.users u where u.id = auth.uid();
  update public.cost_transfer_requests r
     set transfer_date = p_date, from_store = p_from, to_store = p_to, items = v_items, total = v_total, note = nullif(p_note, ''),
         requester_id = coalesce(p_requester_id, r.requester_id), requester_name = coalesce(v_rname, r.requester_name)
   where r.id = p_id;
  insert into public.request_log (kind, requester_name, requester_id, entered_by, store_name, summary, amount, action, ref_id)
  values ('cost_transfer_edit', v_rname, p_requester_id, v_ename, p_from, '申請の修正：' || p_from || '→' || p_to || '（' || p_date || '）', v_total, 'update', p_id::text);
end;
$$;
revoke all on function public.cost_transfer_request_update(uuid, date, text, text, jsonb, text, uuid) from public, anon;
grant execute on function public.cost_transfer_request_update(uuid, date, text, text, jsonb, text, uuid) to authenticated;

-- 承認待ち・却下済みのみ削除可（承認済みはPLに反映済みのため「🔀仕入れ移動」の履歴から取り消す）
create or replace function public.cost_transfer_request_delete(p_id uuid)
returns void language plpgsql security definer set search_path to 'public'
as $$
declare r public.cost_transfer_requests%rowtype; v_ename text;
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  select * into r from public.cost_transfer_requests where id = p_id;
  if r.id is null then raise exception '対象がありません'; end if;
  if r.status = 'approved' then raise exception '承認済みの申請は、PLに反映済みのため削除できません。「🔀仕入れ移動」の履歴から取り消してください'; end if;
  select u.name into v_ename from public.users u where u.id = auth.uid();
  delete from public.cost_transfer_requests where id = p_id;
  insert into public.request_log (kind, requester_name, requester_id, entered_by, store_name, summary, amount, action, ref_id)
  values ('cost_transfer_edit', r.requester_name, r.requester_id, v_ename, r.from_store, '申請の削除：' || r.from_store || '→' || r.to_store || '（' || r.transfer_date || '・元の状態: ' || r.status || '）', r.total, 'delete', p_id::text);
end;
$$;
revoke all on function public.cost_transfer_request_delete(uuid) from public, anon;
grant execute on function public.cost_transfer_request_delete(uuid) to authenticated;
