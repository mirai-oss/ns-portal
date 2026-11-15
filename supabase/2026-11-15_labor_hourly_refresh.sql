-- 2026-11-15 担当A: アルバイト人件費（勤怠）を毎時に取り込み、ダッシュボード・日報に早く反映する（ユーザー指示 2026-11-15）。
-- 流れ（JST 7:00〜23:00 の毎時）: ①:00 スマレジ勤怠取込(直近3日) → ②:10 給与明細取込(当月) → ③:20 給与明細ベースの補正＋ kd_dashboard_daily_summary の人件費列を更新。
--   既存の毎朝の取り込み（8:00勤怠・8:30給与・8:45集計）はそのまま残す（毎時はその間の修正を早く拾うだけ。取り直しは冪等）。
-- 認証: EFは x-notify-secret（app_secrets.notify_slack_secret）を service_role 相当として受ける（EF側も同時に変更）。
-- 追加: 関数 kd_labor_refresh / labor_hourly_finish / labor_hourly_call、pg_cron ジョブ3本。
-- 【rollback】select cron.unschedule('labor-hourly-attendance'); select cron.unschedule('labor-hourly-payroll'); select cron.unschedule('labor-hourly-finish');
--   drop function labor_hourly_call(text), labor_hourly_finish(), kd_labor_refresh();

create or replace function public.kd_labor_refresh() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare n_up int := 0; n_zero int := 0; v_max date := (now() at time zone 'Asia/Tokyo')::date;
begin
  create temporary table _ls on commit drop as select * from public.labor_split_daily(date '2026-10-01', v_max);
  update public.kd_dashboard_daily_summary k set
      labor_pa = l.pa, labor_emp = l.emp_total, labor = l.pa + l.emp_total,
      employee_salary_bonus = l.emp_salary, statutory_welfare = l.emp_statutory, commute_allowance = l.emp_commute, computed_at = now()
    from _ls l
   where k.store_id = l.store_id and k.period_date = l.work_date
     and (k.labor_pa is distinct from l.pa or k.labor_emp is distinct from l.emp_total or k.labor is distinct from l.pa + l.emp_total
          or k.employee_salary_bonus is distinct from l.emp_salary or k.statutory_welfare is distinct from l.emp_statutory or k.commute_allowance is distinct from l.emp_commute);
  get diagnostics n_up = row_count;
  update public.kd_dashboard_daily_summary k set labor_pa = 0, labor_emp = 0, labor = 0, employee_salary_bonus = 0, statutory_welfare = 0, commute_allowance = 0, computed_at = now()
   where k.period_date between date '2026-10-01' and v_max
     and (coalesce(k.labor_pa,0) <> 0 or coalesce(k.labor_emp,0) <> 0 or coalesce(k.labor,0) <> 0)
     and not exists (select 1 from _ls l where l.store_id = k.store_id and l.work_date = k.period_date);
  get diagnostics n_zero = row_count;
  return jsonb_build_object('ok', true, 'updated', n_up, 'zeroed', n_zero);
end $$;
revoke all on function public.kd_labor_refresh() from public, anon, authenticated;
grant execute on function public.kd_labor_refresh() to service_role;

create or replace function public.labor_hourly_finish() returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_cur text := to_char(now() at time zone 'Asia/Tokyo', 'YYYY-MM'); v_prev text := to_char((now() at time zone 'Asia/Tokyo') - interval '1 month', 'YYYY-MM');
        v_day int := extract(day from (now() at time zone 'Asia/Tokyo'))::int; r1 jsonb; r2 jsonb := null; r3 jsonb;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);   -- labor_cost_apply_payroll は service_role のみ（クーロンから内部呼び出し）
  r1 := public.labor_cost_apply_payroll(v_cur);
  if v_day <= 10 then r2 := public.labor_cost_apply_payroll(v_prev); end if;
  r3 := public.kd_labor_refresh();
  return jsonb_build_object('apply_cur', r1, 'apply_prev', r2, 'kd', r3);
end $$;
revoke all on function public.labor_hourly_finish() from public, anon, authenticated;
grant execute on function public.labor_hourly_finish() to service_role;

-- EF 呼び出し（非同期）。p_kind='attendance' は直近3日（今日・昨日・一昨日）、'payroll' は当月
create or replace function public.labor_hourly_call(p_kind text) returns void
language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
declare v_secret text; v_today date := (now() at time zone 'Asia/Tokyo')::date; v_body jsonb; v_url text;
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'labor_hourly_call: notify_slack_secret 未設定'; return; end if;
  if p_kind = 'attendance' then
    v_url := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/smaregi-attendance-sync';
    v_body := jsonb_build_object('date_from', to_char(v_today - 2, 'YYYY-MM-DD'), 'date_to', to_char(v_today, 'YYYY-MM-DD'));
  elsif p_kind = 'payroll' then
    v_url := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/smaregi-payroll-sync';
    v_body := jsonb_build_object('year', extract(year from v_today)::int, 'month', extract(month from v_today)::int);
  else raise exception 'p_kindが不正'; end if;
  perform net.http_post(url := v_url,
    headers := jsonb_build_object('Content-Type','application/json','apikey',c_anon,'Authorization','Bearer ' || c_anon,'x-notify-secret', trim(v_secret)),
    body := v_body, timeout_milliseconds := 150000);
end $$;
revoke all on function public.labor_hourly_call(text) from public, anon, authenticated;
grant execute on function public.labor_hourly_call(text) to service_role;

-- 毎時（JST 7:00〜23:00 ＝ UTC 22:00〜14:00）。重複登録を避けるため先に外す
do $$ begin
  perform cron.unschedule(jobname) from cron.job where jobname in ('labor-hourly-attendance', 'labor-hourly-payroll', 'labor-hourly-finish');
end $$;
select cron.schedule('labor-hourly-attendance', '0 22,23,0-14 * * *', $$select public.labor_hourly_call('attendance')$$);
select cron.schedule('labor-hourly-payroll',    '10 22,23,0-14 * * *', $$select public.labor_hourly_call('payroll')$$);
select cron.schedule('labor-hourly-finish',     '20 22,23,0-14 * * *', $$select public.labor_hourly_finish()$$);
