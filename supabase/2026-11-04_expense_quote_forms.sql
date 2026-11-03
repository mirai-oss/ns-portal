-- 2026-11-04 担当A: 経費申請フォーム(URL)・見積もりフォーム(URL)
-- 【影響】新テーブル quote_requests / quote_options（RLS有効・ポリシー無し＝Edge Function/RPCのみ）、非公開バケット quote-photos、
--   RPC request_form_link / request_form_link_rotate を作り直し（種類に expense・quote を追加。既存の transfer・spot は変えない）、新RPC quote_list。
-- 【rollback】drop function quote_list(text); drop table quote_options, quote_requests; request_form_link系は 2026-10-05_request_forms.sql の定義に戻す。

create table if not exists public.quote_requests (
  id uuid primary key default gen_random_uuid(),
  submitted_at timestamptz not null default now(),
  quote_date date not null,
  store_name text not null,
  requester_id uuid references public.users (id),
  requester_name text,
  subject text not null,
  note text
);
create index if not exists quote_requests_submitted_idx on public.quote_requests (submitted_at desc);
alter table public.quote_requests enable row level security;

create table if not exists public.quote_options (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.quote_requests (id) on delete cascade,
  sort_no int not null default 1,
  vendor_name text,
  amount numeric,
  note text,
  photo_paths text[] not null default '{}'
);
create index if not exists quote_options_req_idx on public.quote_options (request_id, sort_no);
alter table public.quote_options enable row level security;

insert into storage.buckets (id, name, public, file_size_limit)
values ('quote-photos', 'quote-photos', false, 10485760)
on conflict (id) do nothing;
drop policy if exists quote_photos_read on storage.objects;
create policy quote_photos_read on storage.objects for select
  using (bucket_id = 'quote-photos' and public._is_request_admin());
-- 書き込みはservice_role（Edge Function form-submit）のみ

create or replace function public.request_form_link(p_kind text)
returns text language plpgsql security definer set search_path to 'public'
as $$
declare v_key text; v text;
begin
  if not public._is_request_admin() then raise exception '権限がありません（本部・社長・マスターのみ）'; end if;
  v_key := case p_kind when 'transfer' then 'cost_transfer_form_token' when 'spot' then 'spot_form_token'
                       when 'expense' then 'expense_form_token' when 'quote' then 'quote_form_token' else null end;
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

create or replace function public.request_form_link_rotate(p_kind text)
returns text language plpgsql security definer set search_path to 'public'
as $$
declare v_key text; v text := replace(gen_random_uuid()::text, '-', '');
begin
  if not public._is_request_admin() then raise exception '権限がありません（本部・社長・マスターのみ）'; end if;
  v_key := case p_kind when 'transfer' then 'cost_transfer_form_token' when 'spot' then 'spot_form_token'
                       when 'expense' then 'expense_form_token' when 'quote' then 'quote_form_token' else null end;
  if v_key is null then raise exception 'bad kind'; end if;
  insert into public.app_secrets (key, value, updated_at) values (v_key, v, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return v;
end;
$$;

-- 見積もり一覧（月ごと・社長/本部/マスターのみ）。1件=比較用に業者ごとの金額と写真パスを束ねて返す
create or replace function public.quote_list(p_month text)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare v_from timestamptz; v_to timestamptz;
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  v_from := (p_month || '-01')::date::timestamp at time zone 'Asia/Tokyo';
  v_to := ((p_month || '-01')::date + interval '1 month')::timestamp at time zone 'Asia/Tokyo';
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', q.id, 'submitted_at', q.submitted_at, 'quote_date', q.quote_date, 'store', q.store_name,
      'requester', q.requester_name, 'subject', q.subject, 'note', q.note,
      'options', coalesce((select jsonb_agg(jsonb_build_object('vendor', o.vendor_name, 'amount', o.amount, 'note', o.note, 'photos', o.photo_paths) order by o.sort_no)
                           from public.quote_options o where o.request_id = q.id), '[]'::jsonb)
    ) order by q.submitted_at desc)
    from public.quote_requests q where q.submitted_at >= v_from and q.submitted_at < v_to), '[]'::jsonb);
end;
$$;
revoke all on function public.quote_list(text) from public, anon;
grant execute on function public.quote_list(text) to authenticated;
