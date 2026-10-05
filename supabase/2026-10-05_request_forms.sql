-- 2026-10-05 担当A: スポット人件費の申請フォーム（承認制・URL）＋申請フォームURLの発行/再発行＋履歴RPCの拡張
-- ユーザー要望「すべての申請関係はURLを発行（退職処理と同じ形式のUI）」「スポット人件費の申請フォームは承認制」。
-- 前提: 2026-10-05_request_history.sql 適用済み。
-- 【影響】新テーブル spot_labor_requests（RLS有効・ポリシー無し＝service role/RPCのみ）／新RPC4（いずれも社長・本部・マスターのみ）／
--   request_history を作り直し（戻り列に ref_id を追加・スポット申請を合流）。既存の行・既存の挙動は変えない。
-- 【rollback】drop function request_form_link(text), request_form_link_rotate(text), spot_request_get(uuid), spot_request_decide(uuid,text,text);
--   drop table spot_labor_requests; request_history は 2026-10-05_request_history.sql の定義に戻す。

create table if not exists public.spot_labor_requests (
  id uuid primary key default gen_random_uuid(),
  submitted_at timestamptz not null default now(),
  store_name text not null,
  work_date date not null,
  kind text not null check (kind in ('タイミー', 'その他')),
  amount numeric not null check (amount > 0),
  headcount int,
  note text,
  requester_id uuid references public.users (id),
  requester_name text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  approver text,
  approved_at timestamptz,
  reject_reason text
);
create index if not exists spot_labor_requests_submitted_idx on public.spot_labor_requests (submitted_at desc);
alter table public.spot_labor_requests enable row level security;   -- ポリシー無し＝直接の読み書き不可（Edge Function/RPCのみ）

-- 管理者チェック（社長・本部・マスター）
create or replace function public._is_request_admin() returns boolean
language sql stable security definer set search_path to 'public'
as $$ select exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO', 'HQ'))); $$;
revoke all on function public._is_request_admin() from public, anon;
grant execute on function public._is_request_admin() to authenticated;

-- 申請フォームURLの合言葉（transfer=仕入れ移動 / spot=スポット人件費）。無ければ作る。
create or replace function public.request_form_link(p_kind text)
returns text language plpgsql security definer set search_path to 'public'
as $$
declare v_key text; v text;
begin
  if not public._is_request_admin() then raise exception '権限がありません（本部・社長・マスターのみ）'; end if;
  v_key := case p_kind when 'transfer' then 'cost_transfer_form_token' when 'spot' then 'spot_form_token' else null end;
  if v_key is null then raise exception 'bad kind'; end if;
  select a.value into v from public.app_secrets a where a.key = v_key;
  if coalesce(v, '') = '' then
    v := replace(gen_random_uuid()::text, '-', '');
    insert into public.app_secrets (key, value, updated_at) values (v_key, v, now())
      on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;
  return v;
end;
$$;
revoke all on function public.request_form_link(text) from public, anon;
grant execute on function public.request_form_link(text) to authenticated;

-- 再発行（古いURLは即無効）
create or replace function public.request_form_link_rotate(p_kind text)
returns text language plpgsql security definer set search_path to 'public'
as $$
declare v_key text; v text := replace(gen_random_uuid()::text, '-', '');
begin
  if not public._is_request_admin() then raise exception '権限がありません（本部・社長・マスターのみ）'; end if;
  v_key := case p_kind when 'transfer' then 'cost_transfer_form_token' when 'spot' then 'spot_form_token' else null end;
  if v_key is null then raise exception 'bad kind'; end if;
  insert into public.app_secrets (key, value, updated_at) values (v_key, v, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;
revoke all on function public.request_form_link_rotate(text) from public, anon;
grant execute on function public.request_form_link_rotate(text) to authenticated;

-- スポット人件費の申請1件の取得（承認時にGASへ書き込む内容）
create or replace function public.spot_request_get(p_id uuid)
returns table (id uuid, store_name text, work_date date, kind text, amount numeric, headcount int, note text, requester_id uuid, requester_name text, status text)
language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  return query select r.id, r.store_name, r.work_date, r.kind, r.amount, r.headcount, r.note, r.requester_id, r.requester_name, r.status
               from public.spot_labor_requests r where r.id = p_id;
end;
$$;
revoke all on function public.spot_request_get(uuid) from public, anon;
grant execute on function public.spot_request_get(uuid) to authenticated;

-- 承認/却下（承認待ちのものだけ。二重処理は例外）
create or replace function public.spot_request_decide(p_id uuid, p_decision text, p_reason text)
returns void language plpgsql security definer set search_path to 'public'
as $$
declare v_name text; v_n int;
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  if p_decision not in ('approved', 'rejected') then raise exception 'bad decision'; end if;
  select u.name into v_name from public.users u where u.id = auth.uid();
  update public.spot_labor_requests r
     set status = p_decision, approver = v_name, approved_at = now(), reject_reason = case when p_decision = 'rejected' then nullif(left(p_reason, 200), '') else null end
   where r.id = p_id and r.status = 'pending';
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception '既に処理済みか、対象がありません'; end if;
end;
$$;
revoke all on function public.spot_request_decide(uuid, text, text) from public, anon;
grant execute on function public.spot_request_decide(uuid, text, text) to authenticated;

-- 履歴RPCの作り直し（戻り列に ref_id を追加し、スポット人件費の申請を合流）
drop function if exists public.request_history(text);
create or replace function public.request_history(p_month text)
returns table (kind text, occurred_at timestamptz, requester text, summary text, amount numeric, status text,
               decided_at timestamptz, decided_by text, store text, ref_id text)
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_from timestamptz; v_to timestamptz;
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  if p_month is null or p_month !~ '^\d{4}-\d{2}$' then raise exception 'bad month'; end if;
  v_from := ((p_month || '-01')::date)::timestamp at time zone 'Asia/Tokyo';
  v_to := (((p_month || '-01')::date + interval '1 month')::date)::timestamp at time zone 'Asia/Tokyo';
  return query
    select 'cost_transfer'::text, r.submitted_at, coalesce(nullif(r.requester_name, ''), '（申請者の記録なし）')::text,
           (r.from_store || '→' || r.to_store || '／' || coalesce((select string_agg(i ->> 'name', '・') from jsonb_array_elements(r.items) i), '') || '（' || r.transfer_date || '）')::text,
           r.total::numeric, r.status::text, r.approved_at, nullif(r.approver, '')::text, r.from_store::text, r.id::text
    from public.cost_transfer_requests r where r.submitted_at >= v_from and r.submitted_at < v_to
    union all
    select 'spot_labor_request'::text, q.submitted_at, coalesce(nullif(q.requester_name, ''), '（不明）')::text,
           (q.store_name || '／' || q.work_date || '／' || q.kind || case when q.headcount is not null then '／' || q.headcount || '人' else '' end || case when coalesce(q.note, '') <> '' then '／' || q.note else '' end)::text,
           q.amount::numeric, q.status::text, q.approved_at, nullif(q.approver, '')::text, q.store_name::text, q.id::text
    from public.spot_labor_requests q where q.submitted_at >= v_from and q.submitted_at < v_to
    union all
    select 'retirement'::text, h.requested_at, coalesce(h.requester_name, rq.name, '（不明）')::text,
           (coalesce(tu.name, '') || 'さん 退職日 ' || h.effective_date || '（' || coalesce(st.name, '') || '）')::text,
           null::numeric, h.status::text, coalesce(h.approved_at, h.rejected_at), coalesce(ap.name, rj.name)::text, st.name::text, h.id::text
    from public.hr_change_requests h
      left join public.users rq on rq.id = h.requested_by
      left join public.users tu on tu.id = h.user_id
      left join public.stores st on st.id = h.store_id
      left join public.users ap on ap.id = h.approved_by
      left join public.users rj on rj.id = h.rejected_by
    where h.kind = 'retirement' and h.requested_at >= v_from and h.requested_at < v_to
    union all
    select l.kind::text, l.occurred_at, coalesce(nullif(l.requester_name, ''), l.entered_by, '（不明）')::text,
           (coalesce(l.summary, '') || case l.action when 'delete' then '【削除】' when 'update' then '【修正】' else '' end)::text,
           l.amount::numeric, 'direct'::text, null::timestamptz, l.entered_by::text, l.store_name::text, l.id::text
    from public.request_log l where l.occurred_at >= v_from and l.occurred_at < v_to
    order by 2 desc;
end;
$$;
revoke all on function public.request_history(text) from public, anon;
grant execute on function public.request_history(text) to authenticated;
