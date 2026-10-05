-- 2026-10-05 担当A: 申請の承認待ち件数（未読バッジ用）。社長・本部・マスターのみ。前提: 2026-10-05_request_forms.sql 適用済み（_is_request_admin）。
-- 2026-10-05修正: 戻り列名kindと列kindが衝突して実行時エラー(42702)になっていたため、テーブルの別名を付けて修飾した。
-- 【rollback】drop function public.request_pending_counts();
create or replace function public.request_pending_counts()
returns table (kind text, n bigint)
language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  return query
    select 'cost_transfer'::text, count(*) from public.cost_transfer_requests c where c.status = 'pending'
    union all
    select 'spot_labor_request'::text, count(*) from public.spot_labor_requests q where q.status = 'pending'
    union all
    select 'retirement'::text, count(*) from public.hr_change_requests h where h.kind = 'retirement' and h.status = 'pending';
end;
$$;
revoke all on function public.request_pending_counts() from public, anon;
grant execute on function public.request_pending_counts() to authenticated;
