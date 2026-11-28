-- 2026-11-28_deposit_access_fix.sql の取り消し（元のポリシーと権限に戻す）。状態: 下書き（未適用）
drop policy if exists ar_receivables_access on public.ar_receivables;
drop policy if exists ar_deposits_access on public.ar_deposits;
drop policy if exists ar_matching_access on public.ar_matching;
drop policy if exists ar_receivable_attachments_access on public.ar_receivable_attachments;
drop policy if exists ar_recurring_master_access on public.ar_recurring_master;
create policy authenticated_full_access on public.ar_receivables for all to authenticated using (true) with check (true);
create policy authenticated_full_access on public.ar_deposits for all to authenticated using (true) with check (true);
create policy authenticated_full_access on public.ar_matching for all to authenticated using (true) with check (true);
create policy authenticated_full_access on public.ar_receivable_attachments for all to authenticated using (true) with check (true);
create policy authenticated_full_access on public.ar_recurring_master for all to authenticated using (true) with check (true);
drop policy if exists kd_deposit_daily_select on public.kd_deposit_daily;
create policy kd_deposit_daily_select on public.kd_deposit_daily for select to authenticated using ((EXISTS ( SELECT 1
   FROM users u
  WHERE ((u.id = auth.uid()) AND u.is_active AND (u.is_master OR (u.role = ANY (ARRAY['CEO'::text, 'HQ'::text, 'TEAM'::text])) OR ((u.role = 'TENCHO'::text) AND (EXISTS ( SELECT 1
           FROM user_stores us
          WHERE ((us.user_id = u.id) AND (us.store_id = kd_deposit_daily.store_id))))))))));
drop policy if exists kd_deposit_monthly_summary_select on public.kd_deposit_monthly_summary;
create policy kd_deposit_monthly_summary_select on public.kd_deposit_monthly_summary for select to authenticated using ((EXISTS ( SELECT 1
   FROM users u
  WHERE ((u.id = auth.uid()) AND u.is_active AND (u.is_master OR (u.role = ANY (ARRAY['CEO'::text, 'HQ'::text, 'TEAM'::text])) OR ((u.role = 'TENCHO'::text) AND (EXISTS ( SELECT 1
           FROM user_stores us
          WHERE ((us.user_id = u.id) AND (us.store_id = kd_deposit_monthly_summary.store_id))))))))));
grant insert, update, delete, truncate, references, trigger on public.kd_deposit_daily, public.kd_deposit_monthly_summary, public.kd_deposit_daily_v, public.kd_deposit_carry_v to authenticated;
grant all on public.kd_deposit_daily, public.kd_deposit_monthly_summary, public.kd_deposit_daily_v, public.kd_deposit_carry_v to anon;
grant truncate, references, trigger on public.ar_receivables, public.ar_deposits, public.ar_matching, public.ar_receivable_attachments, public.ar_recurring_master to authenticated;
drop function if exists public.ar_visible_receivable_ids();
drop function if exists public.dep_allowed_corp_ids();
drop function if exists public.dep_unrestricted();
