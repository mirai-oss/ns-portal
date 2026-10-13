-- 【事前報告様式（DB変更）】
-- 目的: 店舗間の仕入れ移動（登録・取消・一覧・承認・却下）をGAS/スプレッドシート(DB_PL)なしでSupabaseに統一（担当A・2026-10-13・ユーザー指示「スパベースで統一」）。
--       移動の行は正本 pl_entries に直接書く（source='店舗間移動'・メモ『店舗間移動:<id>:<日付>』・区分F・2行1組）。
-- 追加（新規のみ・既存テーブルの列変更なし）: RPC cost_transfer_add / cost_transfer_cancel / cost_transfer_list / cost_transfer_pending_list / cost_transfer_approve / cost_transfer_reject
-- 権限: master/CEO/HQ のみ（_pl_scope）。service_role可。
-- 併せてEdge keiei-kd-refreshの自動取込(autoSyncFromStgPl)は source='店舗間移動' を無視する（正本をGAS側の古いDB_PLで上書き/削除しないため）。
-- ロールバック: drop function cost_transfer_*; Edgeの無視条件を外す。
-- 実行: supabase db query --linked -f supabase/2026-10-13_cost_transfer_supabase.sql

create or replace function public._ct_write(p_date date, p_from text, p_to text, p_item text, p_amount numeric, p_actor text) returns text
language plpgsql security definer set search_path = public as $$
declare v_from uuid := public._pl_resolve_store(p_from); v_to uuid := public._pl_resolve_store(p_to);
  v_id text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 8); v_ym text := to_char(p_date, 'YYYY-MM'); v_memo text;
  v_fn text; v_tn text;
begin
  if v_from is null then raise exception '移動元の店舗を特定できません: %', p_from; end if;
  if v_to is null then raise exception '移動先の店舗を特定できません: %', p_to; end if;
  if v_from = v_to then raise exception '移動元と移動先は別の店舗にしてください'; end if;
  v_memo := '店舗間移動:' || v_id || ':' || to_char(p_date, 'YYYY-MM-DD');
  perform set_config('app.actor', coalesce(p_actor, 'transfer'), true);
  insert into public.pl_entries (year_month, store_id, item, category, amount, memo, sub_item, source, source_key, created_by, updated_by)
    values (v_ym, v_from, left(p_item, 60) || '（店舗間移動→' || p_to || '）', 'F', -p_amount, v_memo, '', '店舗間移動', 'xfer:' || v_id || ':out', p_actor, p_actor),
           (v_ym, v_to,   left(p_item, 60) || '（店舗間移動←' || p_from || '）', 'F',  p_amount, v_memo, '', '店舗間移動', 'xfer:' || v_id || ':in',  p_actor, p_actor);
  return v_id;
end $$;
revoke all on function public._ct_write(date, text, text, text, numeric, text) from public, anon, authenticated;
grant execute on function public._ct_write(date, text, text, text, numeric, text) to service_role;

-- 登録（管理画面からの直接入力）。p_items=[{item,amount}]
create or replace function public.cost_transfer_add(p_date date, p_from text, p_to text, p_items jsonb, p_actor text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sc jsonb := public._pl_scope(p_actor); v_actor text := sc->>'actor'; r jsonb; v_ids text[] := '{}'; v_total numeric := 0; v_id text; v_amt numeric; v_name text;
begin
  if sc->>'kind' = 'none' then return jsonb_build_object('ok', false, 'error', '店舗間の仕入れ移動は社長・本部のみ登録できます'); end if;
  if p_date is null then return jsonb_build_object('ok', false, 'error', '移動日が不正です'); end if;
  if coalesce(btrim(p_from), '') = '' or coalesce(btrim(p_to), '') = '' then return jsonb_build_object('ok', false, 'error', '移動元・移動先の店舗を選んでください'); end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then return jsonb_build_object('ok', false, 'error', '商品を入力してください'); end if;
  begin
    for r in select value from jsonb_array_elements(p_items) loop
      v_name := btrim(coalesce(r->>'item', '')); v_amt := nullif(btrim(coalesce(r->>'amount', '')), '')::numeric;
      if v_name = '' then raise exception '品名を入力してください'; end if;
      if v_amt is null or v_amt <= 0 then raise exception '「%」の金額を正しく入力してください', v_name; end if;
      v_id := public._ct_write(p_date, btrim(p_from), btrim(p_to), v_name, v_amt, v_actor); v_ids := v_ids || v_id; v_total := v_total + v_amt;
    end loop;
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);   -- 全か無か（途中で失敗したらここまでの書込も巻き戻る）
  end;
  return jsonb_build_object('ok', true, 'id', v_ids[1], 'ids', to_jsonb(v_ids), 'count', array_length(v_ids, 1), 'total', v_total, 'date', p_date, 'fromStore', p_from, 'toStore', p_to);
end $$;
revoke all on function public.cost_transfer_add(date, text, text, jsonb, text) from public, anon;
grant execute on function public.cost_transfer_add(date, text, text, jsonb, text) to authenticated, service_role;

-- 取消（同じIDの2行を削除＝ソフト削除・履歴に残る）
create or replace function public.cost_transfer_cancel(p_id text, p_actor text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sc jsonb := public._pl_scope(p_actor); v_actor text := sc->>'actor'; n int;
begin
  if sc->>'kind' = 'none' then return jsonb_build_object('ok', false, 'error', '店舗間の仕入れ移動の取り消しは社長・本部のみ行えます'); end if;
  if coalesce(btrim(p_id), '') = '' then return jsonb_build_object('ok', false, 'error', 'idが指定されていません'); end if;
  perform set_config('app.actor', v_actor, true);
  update public.pl_entries set deleted_at = now(), updated_at = now(), updated_by = v_actor
    where deleted_at is null and memo like '店舗間移動:' || btrim(p_id) || ':%';
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('ok', false, 'error', '対象の移動が見つかりません（既に取り消し済みの可能性があります）'); end if;
  return jsonb_build_object('ok', true, 'deleted', n);
end $$;
revoke all on function public.cost_transfer_cancel(text, text) from public, anon;
grant execute on function public.cost_transfer_cancel(text, text) to authenticated, service_role;

-- 一覧（直近200件）。移動元(マイナス)・移動先(プラス)の2行が揃ったものだけ
create or replace function public.cost_transfer_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sc jsonb := public._pl_scope(null); v jsonb;
begin
  if sc->>'kind' = 'none' then return jsonb_build_object('ok', false, 'error', '店舗間の仕入れ移動は社長・本部のみ閲覧できます'); end if;
  select coalesce(jsonb_agg(x order by x->>'date' desc), '[]'::jsonb) into v from (
    select jsonb_build_object('id', t.tid, 'date', t.tdate, 'item', max(regexp_replace(t.item, '（店舗間移動[→←][^）]*）$', '')),
             'amount', max(abs(t.amount)), 'fromStore', max(case when t.amount < 0 then t.sname end), 'toStore', max(case when t.amount > 0 then t.sname end)) as x
    from (select (regexp_match(p.memo, '^店舗間移動:([^:]+):(\d{4}-\d{2}-\d{2})$'))[1] tid, (regexp_match(p.memo, '^店舗間移動:([^:]+):(\d{4}-\d{2}-\d{2})$'))[2] tdate,
                 p.item, p.amount, coalesce(nullif(btrim(s.dash_store_name), ''), s.name) sname
          from public.pl_entries p left join public.stores s on s.id = p.store_id where p.deleted_at is null and p.memo ~ '^店舗間移動:') t
    where t.tid is not null group by t.tid, t.tdate having bool_or(t.amount < 0) and bool_or(t.amount > 0)
    order by t.tdate desc limit 200) q;
  return jsonb_build_object('ok', true, 'rows', v);
end $$;
revoke all on function public.cost_transfer_list() from public, anon;
grant execute on function public.cost_transfer_list() to authenticated, service_role;

-- 承認待ち一覧
create or replace function public.cost_transfer_pending_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sc jsonb := public._pl_scope(null);
begin
  if sc->>'kind' = 'none' then return jsonb_build_object('ok', false, 'error', '承認待ち一覧は社長・本部のみ閲覧できます'); end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'submittedAt', r.submitted_at, 'date', r.transfer_date, 'fromStore', r.from_store,
    'toStore', r.to_store, 'items', r.items, 'total', r.total, 'note', coalesce(r.note, ''), 'status', r.status, 'approver', coalesce(r.approver, ''), 'approvedAt', r.approved_at,
    'requesterName', coalesce(r.requester_name, '')) order by r.submitted_at desc) from public.cost_transfer_requests r where r.status = 'pending'), '[]'::jsonb));
end $$;
revoke all on function public.cost_transfer_pending_list() from public, anon;
grant execute on function public.cost_transfer_pending_list() to authenticated, service_role;

-- 承認（PLへ反映＋申請を承認済みに。1つのトランザクションなので二重計上・片落ちが起きない）
create or replace function public.cost_transfer_approve(p_request uuid, p_actor text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sc jsonb := public._pl_scope(p_actor); v_actor text := sc->>'actor'; t record; it jsonb; v_amt numeric; v_ids text[] := '{}'; v_id text; v_nm text;
begin
  if sc->>'kind' = 'none' then return jsonb_build_object('ok', false, 'error', '承認は社長・本部のみ行えます'); end if;
  select * into t from public.cost_transfer_requests where id = p_request for update;
  if not found then return jsonb_build_object('ok', false, 'error', '対象の申請が見つかりません'); end if;
  if t.status <> 'pending' then return jsonb_build_object('ok', false, 'error', '既に' || case when t.status = 'approved' then '承認' else '却下' end || '済みです'); end if;
  begin
    for it in select value from jsonb_array_elements(coalesce(t.items, '[]'::jsonb)) loop
      v_nm := btrim(coalesce(it->>'name', ''));
      v_amt := coalesce(round(nullif(it->>'unitPrice', '')::numeric * nullif(it->>'qty', '')::numeric), nullif(it->>'amount', '')::numeric, 0);
      if v_nm = '' or v_amt <= 0 then continue; end if;
      v_id := public._ct_write(t.transfer_date, t.from_store, t.to_store, v_nm, v_amt, v_actor); v_ids := v_ids || v_id;
    end loop;
    if coalesce(array_length(v_ids, 1), 0) = 0 then raise exception 'PLへ書き込める明細がありませんでした'; end if;
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;
  update public.cost_transfer_requests set status = 'approved', approver = regexp_replace(v_actor, '^[0-9a-f-]{36}:', ''), approved_at = now() where id = p_request;
  return jsonb_build_object('ok', true, 'writtenIds', to_jsonb(v_ids));
end $$;
revoke all on function public.cost_transfer_approve(uuid, text) from public, anon;
grant execute on function public.cost_transfer_approve(uuid, text) to authenticated, service_role;

create or replace function public.cost_transfer_reject(p_request uuid, p_reason text default '', p_actor text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare sc jsonb := public._pl_scope(p_actor); v_actor text := sc->>'actor'; n int;
begin
  if sc->>'kind' = 'none' then return jsonb_build_object('ok', false, 'error', '却下は社長・本部のみ行えます'); end if;
  update public.cost_transfer_requests set status = 'rejected', reject_reason = left(coalesce(p_reason, ''), 200),
    approver = regexp_replace(v_actor, '^[0-9a-f-]{36}:', ''), approved_at = now() where id = p_request and status = 'pending';
  get diagnostics n = row_count;
  if n = 0 then return jsonb_build_object('ok', false, 'error', '対象の申請が見つからないか、既に処理済みです'); end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.cost_transfer_reject(uuid, text, text) from public, anon;
grant execute on function public.cost_transfer_reject(uuid, text, text) to authenticated, service_role;
