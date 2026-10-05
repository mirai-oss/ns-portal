-- 2026-10-05 担当A: 申請履歴（月ごと）＋申請者の記録（仕入れ移動・スポット人件費）
-- ユーザー要望「退職申請・スポット人件費・仕入れ移動など、各申請の履歴を月ごとに見たい（いつ・誰が申請し、いつ・誰が承認したか）。
-- 仕入れ移動にも『誰が申請したか』を選べるように」。
-- 【影響】cost_transfer_requestsに列2つ追加（既存行はnullのまま）／新テーブル request_log（RLS有効・ポリシー無し＝service roleのみ）／
--   新RPC staff_directory（ログイン済みのみ・従業員名簿）／新RPC request_history（社長・本部・マスターのみ）。
--   退職申請（hr_change_requests・担当B所有）は読み取りのみ（変更しない）。
-- 【rollback】drop function request_history(text), staff_directory(); drop table request_log; alter table cost_transfer_requests drop column requester_name, drop column requester_id;

alter table public.cost_transfer_requests add column if not exists requester_name text;
alter table public.cost_transfer_requests add column if not exists requester_id uuid references public.users (id);
comment on column public.cost_transfer_requests.requester_name is '申請者（フォームで選んだ従業員名）。2026-10-05追加。それ以前の行はnull';

-- 申請の「履歴だけ」を残すログ（承認フローが無いもの＝スポット人件費の入力・管理者による仕入れ移動の直接登録）
create table if not exists public.request_log (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('spot_labor', 'cost_transfer_direct')),
  occurred_at timestamptz not null default now(),
  requester_name text,                 -- 申請者（フォームで選んだ従業員名）
  requester_id uuid references public.users (id),
  entered_by text,                     -- ダッシュボードにログインして入力した人（表示名）
  store_name text,
  summary text,
  amount numeric,
  action text not null default 'create' check (action in ('create', 'update', 'delete')),
  ref_id text,
  created_at timestamptz not null default now()
);
create index if not exists request_log_occurred_idx on public.request_log (occurred_at desc);
alter table public.request_log enable row level security;   -- ポリシー無し＝service role(GAS/Edge Function)のみ読み書き可

-- 従業員名簿（申請者の選択肢）。ログイン済みユーザーのみ。名前とIDだけ返す。
create or replace function public.staff_directory()
returns table (id uuid, name text)
language sql stable security definer set search_path to 'public'
as $$
  select u.id, u.name from public.users u
  where auth.uid() is not null and u.is_active and coalesce(u.name, '') <> ''
  order by u.name;
$$;
revoke all on function public.staff_directory() from public, anon;
grant execute on function public.staff_directory() to authenticated;

-- 申請履歴（月ごと）。社長・本部・マスターのみ。p_month='YYYY-MM'（日本時間の月）
create or replace function public.request_history(p_month text)
returns table (kind text, occurred_at timestamptz, requester text, summary text, amount numeric, status text,
               decided_at timestamptz, decided_by text, store text)
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_from timestamptz; v_to timestamptz; v_ok boolean;
begin
  select exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO', 'HQ'))) into v_ok;
  if not v_ok then raise exception 'forbidden'; end if;
  if p_month is null or p_month !~ '^\d{4}-\d{2}$' then raise exception 'bad month'; end if;
  v_from := ((p_month || '-01')::date)::timestamp at time zone 'Asia/Tokyo';
  v_to := (((p_month || '-01')::date + interval '1 month')::date)::timestamp at time zone 'Asia/Tokyo';
  return query
    select 'cost_transfer'::text, r.submitted_at, coalesce(nullif(r.requester_name, ''), '（申請者の記録なし）')::text,
           (r.from_store || '→' || r.to_store || '／' || coalesce((select string_agg(i ->> 'name', '・') from jsonb_array_elements(r.items) i), '') || '（' || r.transfer_date || '）')::text,
           r.total::numeric, r.status::text, r.approved_at, nullif(r.approver, '')::text, r.from_store::text
    from public.cost_transfer_requests r where r.submitted_at >= v_from and r.submitted_at < v_to
    union all
    select 'retirement'::text, h.requested_at, coalesce(rq.name, '（不明）')::text,
           (coalesce(tu.name, '') || 'さん 退職日 ' || h.effective_date || '（' || coalesce(st.name, '') || '）')::text,
           null::numeric, h.status::text, coalesce(h.approved_at, h.rejected_at), coalesce(ap.name, rj.name)::text, st.name::text
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
           l.amount::numeric, 'direct'::text, null::timestamptz, l.entered_by::text, l.store_name::text
    from public.request_log l where l.occurred_at >= v_from and l.occurred_at < v_to
    order by 2 desc;
end;
$$;
revoke all on function public.request_history(text) from public, anon;
grant execute on function public.request_history(text) to authenticated;
