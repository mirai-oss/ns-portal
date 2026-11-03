-- 2026-11-05 担当A: 見積もりの「選ぶ/却下/保留」と本部タスク連動
-- 【影響】quote_requests に列追加(状態・選んだ会社・判断者など)、quote_list の戻りを拡張、新RPC quote_decide、request_pending_counts に quote(承認待ち+保留)を追加。
-- 【rollback】alter table quote_requests drop column ...; drop function quote_decide(uuid,text,uuid,text); quote_list/request_pending_counts は前版(2026-11-04系)に戻す。
alter table public.quote_requests add column if not exists status text not null default 'pending';
alter table public.quote_requests drop constraint if exists quote_requests_status_chk;
alter table public.quote_requests add constraint quote_requests_status_chk check (status in ('pending','on_hold','selected','rejected'));
alter table public.quote_requests add column if not exists selected_option_id uuid;
alter table public.quote_requests add column if not exists decided_by text;
alter table public.quote_requests add column if not exists decided_at timestamptz;
alter table public.quote_requests add column if not exists hold_reason text;
alter table public.quote_requests add column if not exists task_id uuid references public.hq_tasks (id) on delete set null;

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
      'status', q.status, 'selected_option_id', q.selected_option_id, 'decided_by', q.decided_by, 'decided_at', q.decided_at, 'hold_reason', q.hold_reason, 'task_id', q.task_id,
      'options', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'vendor', o.vendor_name, 'amount', o.amount, 'note', o.note, 'photos', o.photo_paths) order by o.sort_no)
                           from public.quote_options o where o.request_id = q.id), '[]'::jsonb),
      'steps', coalesce((select jsonb_agg(jsonb_build_object('title', s.title, 'done', s.completed_at is not null) order by s.sort_order)
                         from public.hq_task_steps s where s.task_id = q.task_id), '[]'::jsonb)
    ) order by q.submitted_at desc)
    from public.quote_requests q where q.submitted_at >= v_from and q.submitted_at < v_to), '[]'::jsonb);
end;
$$;

-- 判断: select(会社を決める) / hold(保留) / reject(却下)。決定済み(selected/rejected)は変更不可
create or replace function public.quote_decide(p_id uuid, p_action text, p_option uuid default null, p_reason text default null)
returns void language plpgsql security definer set search_path to 'public'
as $$
declare q record; o record; v_name text; v_n int;
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  if p_action not in ('select','hold','reject') then raise exception 'bad action'; end if;
  select * into q from public.quote_requests where id = p_id for update;
  if q is null then raise exception '見積もりが見つかりません'; end if;
  if q.status in ('selected','rejected') then raise exception 'すでに決定済みです'; end if;
  select u.name into v_name from public.users u where u.id = auth.uid();

  if p_action = 'select' then
    select * into o from public.quote_options where id = p_option and request_id = p_id;
    if o is null then raise exception '会社を選んでください'; end if;
    update public.quote_requests set status = 'selected', selected_option_id = o.id, decided_by = v_name, decided_at = now(), hold_reason = null where id = p_id;
    if q.task_id is not null then
      update public.hq_task_steps set title = '見積もりを決定 → ' || coalesce(o.vendor_name, '（業者名なし）') || case when o.amount is not null then '（' || to_char(o.amount, 'FM999,999,999') || '円）' else '' end,
             completed_at = now(), completed_by = auth.uid(), updated_at = now()
        where task_id = q.task_id and procedure_note = 'quote:select';
      update public.hq_task_steps set title = '【' || coalesce(o.vendor_name, '決定業者') || '】' || title, updated_at = now()
        where task_id = q.task_id and procedure_note in ('quote:date','quote:done','quote:pay') and title not like '【%';
      update public.hq_tasks set status = 'doing', title = '見積もり: ' || q.subject || '（' || q.store_name || '）→ ' || coalesce(o.vendor_name, '決定済み'), updated_at = now() where id = q.task_id and status = 'todo';
      insert into public.hq_task_activity (task_id, actor_id, kind, detail) values (q.task_id, auth.uid(), 'comment', '見積もりで ' || coalesce(o.vendor_name, '') || ' に決定');
    end if;
  elsif p_action = 'hold' then
    update public.quote_requests set status = 'on_hold', hold_reason = nullif(left(p_reason, 200), ''), decided_by = v_name, decided_at = now() where id = p_id;
    if q.task_id is not null then
      insert into public.hq_task_activity (task_id, actor_id, kind, detail) values (q.task_id, auth.uid(), 'comment', '見積もりを保留' || coalesce('：' || nullif(left(p_reason, 200), ''), ''));
    end if;
  else
    update public.quote_requests set status = 'rejected', hold_reason = nullif(left(p_reason, 200), ''), decided_by = v_name, decided_at = now() where id = p_id;
    if q.task_id is not null then
      update public.hq_task_steps set title = '見積もりを却下' || coalesce('（' || nullif(left(p_reason, 200), '') || '）', ''), completed_at = now(), completed_by = auth.uid(), updated_at = now()
        where task_id = q.task_id and procedure_note = 'quote:select';
      delete from public.hq_task_steps where task_id = q.task_id and procedure_note in ('quote:date','quote:done','quote:pay');
      update public.hq_tasks set status = 'done', completed_at = now(), updated_at = now() where id = q.task_id;
      insert into public.hq_task_activity (task_id, actor_id, kind, detail) values (q.task_id, auth.uid(), 'comment', '見積もりを却下');
    end if;
  end if;
end;
$$;
revoke all on function public.quote_decide(uuid, text, uuid, text) from public, anon;
grant execute on function public.quote_decide(uuid, text, uuid, text) to authenticated;

create or replace function public.request_pending_counts() returns table (kind text, n bigint)
language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  return query
    select 'cost_transfer'::text, count(*) from public.cost_transfer_requests c where c.status = 'pending'
    union all
    select 'spot_labor_request'::text, count(*) from public.spot_labor_requests q where q.status = 'pending'
    union all
    select 'retirement'::text, count(*) from public.hr_change_requests h where h.kind = 'retirement' and h.status = 'pending'
    union all
    select 'expense'::text, count(*) from public.expense_requests e where e.status = 'pending'
    union all
    select 'quote'::text, count(*) from public.quote_requests z where z.status in ('pending', 'on_hold');   -- 保留中も未読バッジに残す
end;
$$;
