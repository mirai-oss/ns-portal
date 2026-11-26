-- 2026-11-26_close_anon_exposure.sql を元に戻す（何か動かなくなったときだけ使う）
do $$
declare n text; k "char";
begin
  foreach n in array array[
    'ai_users_v','api_cost_daily','ar_deposits','ar_receivable_attachments','ar_receivables','ar_recurring_master',
    'cash_handoff_role_scope','google_review_legacy_compare_v','google_review_store_daily_v','import_status_today',
    'labor_allocation_compare_report','labor_salary_daily_weight','labor_salary_pay_type','sync_status_v']
  loop
    select c.relkind into k from pg_class c join pg_namespace s on s.oid=c.relnamespace where s.nspname='public' and c.relname=n;
    if k is null then continue; end if;
    execute format('grant select on public.%I to anon', n);
    if k in ('r','p') then
      execute format('drop policy if exists authenticated_full_access on public.%I', n);
      execute format('alter table public.%I disable row level security', n);
    end if;
  end loop;
end $$;

-- 追加分（ar_matching）
drop policy if exists authenticated_full_access on public.ar_matching;
alter table public.ar_matching disable row level security;
grant select, insert, update, delete on public.ar_matching to anon;
