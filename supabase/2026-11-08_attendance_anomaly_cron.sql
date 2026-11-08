-- =============================================================
-- 2026-11-08 勤怠の異常値チェック（smaregi-attendance-anomaly-check）を毎朝 10:00 JST に pg_cron から呼ぶ
-- ユーザー指示: 「毎朝異常値アラートを出すのを 8 時ではなく 10 時に変更」
--   これまで: 取込ワークフロー（08:00・GitHub Actions）の中から呼んでいた → 取込 EF の 504（150 秒超）で書き込み完了前に走り「対象 0 件」になる日があった。
--   これから: pg_cron `attendance-anomaly-check` = 01:00 UTC（10:00 JST）→ attendance_anomaly_check_trigger() → EF（x-notify-secret）。
--   対象日は EF の既定（昨日）。手で流すときは日付を渡す: select public.attendance_anomaly_check_trigger('2026-11-06', '2026-11-07');
-- 通知先は Slack の勤怠確認チャンネル（LINE は 2026-11-08 停止）。既に送った異常値は dedupe（alert id）で二重送信されない。
-- =============================================================
create or replace function public.attendance_anomaly_check_trigger(p_date_from date default null, p_date_to date default null)
returns void
language plpgsql
security definer
set search_path to 'public', 'net', 'extensions'
as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/smaregi-attendance-anomaly-check';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_req bigint; v_body jsonb;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then
    raise warning 'attendance_anomaly_check_trigger: app_secrets.notify_slack_secret が未設定';
    return;
  end if;
  v_body := jsonb_build_object('trigger', 'pg_cron');
  if p_date_from is not null then v_body := v_body || jsonb_build_object('date_from', to_char(p_date_from, 'YYYY-MM-DD')); end if;
  if p_date_to   is not null then v_body := v_body || jsonb_build_object('date_to',   to_char(p_date_to,   'YYYY-MM-DD')); end if;
  select net.http_post(
    url := c_fn,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', c_anon,
      'Authorization', 'Bearer ' || c_anon,
      'x-notify-secret', trim(v_secret)),
    body := v_body,
    timeout_milliseconds := 120000
  ) into v_req;
end $$;
revoke all on function public.attendance_anomaly_check_trigger(date, date) from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'attendance-anomaly-check') then
    perform cron.unschedule('attendance-anomaly-check');
  end if;
  perform cron.schedule('attendance-anomaly-check', '0 1 * * *', $cmd$select public.attendance_anomaly_check_trigger()$cmd$);
end $$;

-- =============================================================
-- 取りこぼし拾い（ユーザー指示 2026-11-08「それでも勤怠履歴がない場合は、勤怠が入ったらすぐに異常値アラートを発火させて」）
--   EF は実行のたびに sf_attendance_anomaly_runs（日付ごと・対象行数 checked）を書く。
--   10:00 の実行で昨日の行が 0 件（checked=0）だったら、15 分おき（10:15〜21:45 JST）に「昨日の行が入ったか」を見て、
--   入っていて、かつ最後の書き込みから 3 分以上たっていれば（取込が終わった印）EF を流し直す。流れたら checked>0 になるので止まる。
-- =============================================================
create table if not exists public.sf_attendance_anomaly_runs (
  date_to       date primary key,              -- 対象の終わりの日（既定=昨日）
  date_from     date,
  checked       int not null default 0,        -- 対象になった labor_cost_daily の行数（0=まだ取込前）
  anomaly_count int not null default 0,
  slack_sent    int not null default 0,
  trigger       text,
  ran_at        timestamptz not null default now()
);
alter table public.sf_attendance_anomaly_runs enable row level security;
comment on table public.sf_attendance_anomaly_runs is '勤怠の異常値チェック（EF smaregi-attendance-anomaly-check）の実行記録。取りこぼし拾い attendance_anomaly_catchup() の判定に使う';

create or replace function public.attendance_anomaly_catchup()
returns text
language plpgsql
security definer
set search_path to 'public', 'net', 'extensions'
as $$
declare
  v_yday date := ((now() at time zone 'Asia/Tokyo')::date - 1);
  v_run  sf_attendance_anomaly_runs%rowtype;
  v_rows int; v_last timestamptz;
begin
  select * into v_run from sf_attendance_anomaly_runs where date_to = v_yday;
  if found and v_run.checked > 0 then return 'done'; end if;                      -- もう対象ありで流れている
  if not found and (now() at time zone 'Asia/Tokyo')::time < time '10:05' then return 'before_main'; end if;   -- 10:00 の本番前
  select count(*), max(updated_at) into v_rows, v_last from labor_cost_daily where work_date = v_yday;
  if coalesce(v_rows, 0) = 0 then return 'no_rows_yet'; end if;                   -- まだ取込前
  if v_last > now() - interval '3 minutes' then return 'still_importing'; end if;  -- 取込中（書き込みが続いている）
  perform public.attendance_anomaly_check_trigger(v_yday, v_yday);
  return 'fired';
end $$;
revoke all on function public.attendance_anomaly_catchup() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'attendance-anomaly-catchup') then
    perform cron.unschedule('attendance-anomaly-catchup');
  end if;
  -- 10:15〜21:45 JST の 15 分おき（= 01:15〜12:45 UTC）
  perform cron.schedule('attendance-anomaly-catchup', '15,30,45 1-12 * * *', $cmd$select public.attendance_anomaly_catchup()$cmd$);
end $$;
