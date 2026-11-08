-- =============================================================
-- 2026-11-08 未対応の Slack ボタン（承認・却下・○×・確認・判断依頼）のリマインド
-- ユーザー指示: 「承認、却下等選ぶものは全て完了してないものを今後リマインドで流してください」
--
-- 仕組み: pg_cron → public.pending_reminders_trigger() → EF pending-reminders
--   EF が未対応のものを集め、最初に送ったメッセージと同じボタン付きで「⏰ リマインド」を再送する。
--   再送したメッセージの台帳 id は各テーブルの *_notification_ids に追加される（ボタンが押されたら全部まとめて「済」に書き換わる）。
--   対象: sf_attendance_alerts(open=店長の○×待ち / fix_requested=マスターの承認待ち)
--         sf_attendance_requests(pending=マスターの承認待ち)
--         sf_attendance_smaregi_changes(open=「確認した」待ち)
--         decision_requests(pending かつ期限内=Claude の判断依頼。期限切れは expired にして締める)
-- 間隔（2026-11-08 ユーザー決定）: 最後の連絡（最初の通知 or 前回のリマインド）から 12 時間たったら送り、完了するまで 12 時間おきに送り続ける。
--   実装: pg_cron を 08:00〜22:00 JST の毎時 0 分に回し（深夜は送らない。夜中に 12 時間を越えたものは朝 8 時に送る）、EF に min_age_hours=12 を渡す。
--   例: 朝 8:00 のアラート → 20:00 → 翌 8:00 → 20:00 …／15:00 のフォーム申請 → 翌 8:00（3:00 は夜間なので送らない）→ 20:00 …
--   変更は cron.alter_job（時間帯）か pending_reminders_trigger() の min_age_hours（間隔）で。
-- =============================================================

-- 1) リマインド回数・最終リマインド時刻（状態ではなく連絡の記録）
alter table sf_attendance_alerts          add column if not exists reminded_at timestamptz, add column if not exists remind_count int not null default 0;
alter table sf_attendance_requests        add column if not exists reminded_at timestamptz, add column if not exists remind_count int not null default 0;
alter table sf_attendance_smaregi_changes add column if not exists reminded_at timestamptz, add column if not exists remind_count int not null default 0;
alter table decision_requests             add column if not exists reminded_at timestamptz, add column if not exists remind_count int not null default 0,
                                          add column if not exists reminder_notification_ids uuid[] not null default '{}'::uuid[];
comment on column decision_requests.reminder_notification_ids is 'リマインドで再送した Slack メッセージの台帳 id。回答時に元メッセージと一緒に「済」へ書き換える';

-- 2) EF を呼ぶ関数（google_reviews_fetch_trigger と同じ作り: app_secrets.notify_slack_secret を x-notify-secret に載せる）
create or replace function public.pending_reminders_trigger()
returns void
language plpgsql
security definer
set search_path to 'public', 'net', 'extensions'
as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/pending-reminders';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_req bigint;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then
    raise warning 'pending_reminders_trigger: app_secrets.notify_slack_secret が未設定';
    return;
  end if;
  select net.http_post(
    url := c_fn,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', c_anon,
      'Authorization', 'Bearer ' || c_anon,
      'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('trigger', 'pg_cron', 'min_age_hours', 12),
    timeout_milliseconds := 120000
  ) into v_req;
end $$;
revoke all on function public.pending_reminders_trigger() from public, anon, authenticated;

-- 3) 08:00〜22:00 JST の毎時 0 分（= 23:00・00:00〜13:00 UTC）。深夜は回さない
do $$
begin
  if exists (select 1 from cron.job where jobname = 'pending-reminders') then
    perform cron.unschedule('pending-reminders');
  end if;
  perform cron.schedule('pending-reminders', '0 23,0-13 * * *', $cmd$select public.pending_reminders_trigger()$cmd$);
end $$;
