-- =============================================================
-- 2026-11-08 勤怠フォーム（kintai.html）: 日付と店舗を選んだら「その日・その店舗の勤怠一覧」を出し、人を選ぶと修正前の値が入る
-- ユーザー指示: 「修正前の状態が分からないと修正しにくい。日付と店舗を選んだらその日の勤怠情報が出て、誰を修正するか選ぶと修正前の勤怠が出て編集できるように」
--   RPC sf_attendance_form_day(p_store_id, p_work_date): labor_cost_daily のその日の行（従業員名・出勤・退勤・休憩・勤務分・ロック・承認待ちの申請あり）
--   権限: その店舗を管理できる人（sf_can_manage）は全員分、それ以外は自分の行だけ。時刻は JST の "YYYY-MM-DDTHH:MM" 文字列で返す（画面でそのまま使う）
-- =============================================================
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
