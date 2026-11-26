-- 戻し: 2026-11-26_form_day_seconds.sql の前（本番の定義＝2026-11-08 と同一を確認済み）に戻す
create or replace function public.sf_attendance_form_day(p_store_id uuid, p_work_date date)
returns table (
  labor_cost_daily_id uuid, user_id uuid, name text,
  clock_in text, clock_out text, break_start_1 text, break_end_1 text, break_start_2 text, break_end_2 text,
  worked_minutes int, break_minutes int, locked boolean, pending boolean, source text
)
language sql stable security definer set search_path = public as $$
  select l.id, l.user_id, u.name,
         to_char(l.clock_in  at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI'),
         to_char(l.clock_out at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI'),
         to_char(l.break_start_1 at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI'),
         to_char(l.break_end_1   at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI'),
         to_char(l.break_start_2 at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI'),
         to_char(l.break_end_2   at time zone 'Asia/Tokyo', 'YYYY-MM-DD"T"HH24:MI'),
         l.worked_minutes::int, l.break_minutes::int, (l.manual_fixed_at is not null),
         exists (select 1 from sf_attendance_requests r where r.user_id = l.user_id and r.work_date = l.work_date and r.store_id = l.store_id and r.status = 'pending'),
         l.source
  from labor_cost_daily l join users u on u.id = l.user_id
  where l.store_id = p_store_id and l.work_date = p_work_date
    and (sf_can_manage(p_store_id) or l.user_id = auth.uid())
  order by l.clock_in nulls last, u.name;
$$;
revoke all on function public.sf_attendance_form_day(uuid, date) from public, anon;
grant execute on function public.sf_attendance_form_day(uuid, date) to authenticated;
