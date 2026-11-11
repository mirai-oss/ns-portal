-- =============================================================
-- 監視の相互確認（見張りの見張り）第 1 段（2026-11-11 ユーザー承認）
--   目的: 定期実行や監視そのものが止まったときに気づけるようにする。ふだんは何も通知しない。止まったときだけ、Slack（#本部-開発システム）に 1 件。
--   しくみ: 監視ごとに「最後に正常に動いた時刻」を調べ、決めた時間（max_silence_minutes）を過ぎていたら「停止」とみなす。
--     source='cron'  … DB の定期実行（pg_cron）。cron.job_run_details の最後の成功の時刻
--     source='query' … データの新しさで判断（Mac mini の日次取込＝import_runs／画面の計測＝kd_perf_log／スマレジの勤怠取込＝labor_cost_daily）
--     source='beat'  … 外の処理が「動いた」と知らせてくる印（monitor_beat）。例: GitHub から毎朝動く計測レポートの判定
--   通知: 新しく「停止」になったものがあるときに 1 件（同じ停止は 24 時間に 1 回まで）。復旧したら状態を戻すだけ（通知しない）。
--   止め方: update monitor_watch set enabled=false where key='…'／全体は cron.unschedule('monitor-check')。戻し: 2026-11-15_monitor_watch_rollback.sql
--   既存の表・関数・定期実行は変えていない（新しい表 1 つ・関数 3 つ・定期実行 1 つを足すだけ）。
-- =============================================================
create table if not exists public.monitor_watch (
  key text primary key,
  label text not null,
  source text not null check (source in ('cron', 'query', 'beat')),
  cron_jobname text,
  max_silence_minutes integer not null check (max_silence_minutes > 0),
  last_ok_at timestamptz,
  checked_at timestamptz,
  state text not null default 'ok' check (state in ('ok', 'stale')),
  stale_since timestamptz,
  alerted_at timestamptz,
  enabled boolean not null default true,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.monitor_watch enable row level security;   -- ポリシーなし＝service_role と DB 内の関数だけ
revoke all on public.monitor_watch from anon, authenticated;

insert into public.monitor_watch(key, label, source, cron_jobname, max_silence_minutes, note) values
  ('cron:attendance-anomaly-check',      '毎朝の勤怠確認',                 'cron', 'attendance-anomaly-check',      1560, '1 日 1 回（10:00）。26 時間'),
  ('cron:attendance-anomaly-catchup',    '勤怠確認の取りこぼし拾い',       'cron', 'attendance-anomaly-catchup',     840, '10:15〜21:45 に 15 分おき。夜の空きがあるため 14 時間'),
  ('cron:pending-reminders',             '未対応のリマインド',             'cron', 'pending-reminders',              660, '8〜22 時の毎時。夜の空きがあるため 11 時間'),
  ('cron:payroll-consistency-check',     '給与・手渡しの整合チェック',     'cron', 'payroll-consistency-check',     1560, '1 日 1 回'),
  ('cron:cash-handoff-incomplete-alert', '現金手渡しの期限の確認',         'cron', 'cash-handoff-incomplete-alert', 1560, '1 日 1 回'),
  ('cron:google-reviews-daily',          'Google 口コミの取得',            'cron', 'google-reviews-daily',          1560, '1 日 1 回'),
  ('cron:slack-link-sync',               'Slack の紐づけの同期',           'cron', 'slack-link-sync',                 60, '10 分おき'),
  ('cron:slack-link-remind',             'Slack 未連携の確認',             'cron', 'slack-link-remind',             1560, '1 日 1 回'),
  ('query:mac_dispatch',                 'Mac mini の日次取込',            'query', null,                            840, '取込の実行記録（import_runs）の新しさ。夜の空きがあるため 14 時間'),
  ('query:attendance_sync',              'スマレジの勤怠取込',             'query', null,                           1800, '勤怠実績の更新の新しさ。30 時間'),
  ('query:perf_ingest',                  '画面の速度の計測',               'query', null,                           2160, '計測（kd_perf_log）の新しさ。36 時間'),
  ('beat:perflog_daily',                 '計測レポートの判定（毎朝）',     'beat', null,                            1560, 'keiei-api-perflog の op=notify が動くたびに印を付ける')
on conflict (key) do nothing;

-- 外の処理が「動いた」と知らせる（service_role だけ）
create or replace function public.monitor_beat(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('request.jwt.claims', true), '') <> '' and coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    raise exception '権限がありません';
  end if;
  update monitor_watch set last_ok_at = now(), updated_at = now() where key = p_key and source = 'beat';
  return jsonb_build_object('ok', found, 'key', p_key);
end $$;
revoke all on function public.monitor_beat(text) from public, anon, authenticated;
grant execute on function public.monitor_beat(text) to service_role;

-- 監視ごとの「最後に正常に動いた時刻」
create or replace function public.monitor_last_ok(p_key text)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare w monitor_watch%rowtype; v timestamptz;
begin
  select * into w from monitor_watch where key = p_key;
  if not found then return null; end if;
  if w.source = 'cron' then
    select max(d.start_time) into v from cron.job j join cron.job_run_details d on d.jobid = j.jobid
     where j.jobname = w.cron_jobname and d.status = 'succeeded';
  elsif w.key = 'query:mac_dispatch' then
    select max(created_at) into v from import_runs;
  elsif w.key = 'query:attendance_sync' then
    select max(updated_at) into v from labor_cost_daily where source = 'smaregi';
  elsif w.key = 'query:perf_ingest' then
    select max(created_at) into v from kd_perf_log;
  else
    v := w.last_ok_at;
  end if;
  return v;
end $$;
revoke all on function public.monitor_last_ok(text) from public, anon, authenticated;

-- 確認（定期実行から 1 時間に 1 回）。p_notify=false は状態を更新せず、結果だけ返す（確認用）
create or replace function public.monitor_check(p_notify boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare w record; v_last timestamptz; v_stale boolean; v_new text[] := '{}'; v_all jsonb := '[]'::jsonb; v_text text; v_h numeric;
begin
  if coalesce(current_setting('request.jwt.claims', true), '') <> '' and coalesce(current_setting('request.jwt.claims', true)::jsonb ->> 'role', '') <> 'service_role' then
    raise exception '権限がありません';
  end if;
  for w in select * from monitor_watch where enabled order by key loop
    v_last := monitor_last_ok(w.key);
    -- 一度も記録が無いものは、登録した時刻から数える（登録した直後に「停止」としない）
    v_stale := coalesce(v_last, w.created_at) < now() - make_interval(mins => w.max_silence_minutes);
    v_h := round((extract(epoch from (now() - coalesce(v_last, w.created_at))) / 3600)::numeric, 1);
    v_all := v_all || jsonb_build_object('key', w.key, 'label', w.label, 'last_ok_at', v_last, 'hours', v_h, 'stale', v_stale);
    if v_stale and (w.alerted_at is null or w.alerted_at < now() - interval '24 hours') then
      v_new := v_new || format('・%s（最後に動いたのは %s 時間前・基準 %s 時間）', w.label, v_h, round(w.max_silence_minutes / 60.0, 1));
    end if;
    if p_notify then
      update monitor_watch set
        last_ok_at = case when source = 'beat' then last_ok_at else v_last end, checked_at = now(),
        state = case when v_stale then 'stale' else 'ok' end,
        stale_since = case when v_stale then coalesce(stale_since, now()) else null end,
        alerted_at = case when not v_stale then null
                          when alerted_at is null or alerted_at < now() - interval '24 hours' then now() else alerted_at end,
        updated_at = now()
      where key = w.key;
    end if;
  end loop;
  if array_length(v_new, 1) > 0 then
    v_text := format('⚠️ システム障害｜監視の停止｜%s 件', array_length(v_new, 1)) || E'\n' || array_to_string(v_new, E'\n')
      || E'\n止まっている処理を確認してください。復旧すると、この知らせは自動で止まります（同じ停止は 24 時間に 1 回だけ知らせます）。';
    if p_notify then
      begin perform notify_route_send('slack', 'hq.dev_system', v_text); exception when others then null; end;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'notified', p_notify and array_length(v_new, 1) > 0, 'new_stale', coalesce(array_length(v_new, 1), 0), 'text', v_text, 'items', v_all);
end $$;
revoke all on function public.monitor_check(boolean) from public, anon, authenticated;
grant execute on function public.monitor_check(boolean) to service_role;

-- 1 時間に 1 回（毎時 20 分）
do $$ begin
  if exists (select 1 from cron.job where jobname = 'monitor-check') then perform cron.unschedule('monitor-check'); end if;
  perform cron.schedule('monitor-check', '20 * * * *', 'select public.monitor_check(true)');
end $$;
