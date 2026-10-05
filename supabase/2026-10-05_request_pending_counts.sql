-- 2026-10-05 担当A: 申請の承認待ち件数（未読バッジ用）。社長・本部・マスターのみ。前提: 2026-10-05_request_forms.sql 適用済み（_is_request_admin）。
-- 【rollback】drop function public.request_pending_counts();
create or replace function public.request_pending_counts()
returns table (kind text, n bigint)
language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  return query
    select 'cost_transfer'::text, count(*) from public.cost_transfer_requests where status = 'pending'
    union all
    select 'spot_labor_request'::text, count(*) from public.spot_labor_requests where status = 'pending'
    union all
    select 'retirement'::text, count(*) from public.hr_change_requests where kind = 'retirement' and status = 'pending';
end;
$$;
revoke all on function public.request_pending_counts() from public, anon;
grant execute on function public.request_pending_counts() to authenticated;
