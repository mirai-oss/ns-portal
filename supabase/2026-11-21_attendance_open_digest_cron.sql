-- 2026-11-21 担当B（社長依頼）— 未完了の勤怠確認を、社長とチーム長へ個人 DM で毎朝 1 通にまとめる
--  社長: 「私とチーム長にはまとめて個人 DM に、完了していない勤怠確認のリストを送る」
--  仕組み: pg_cron（毎朝 9:00 日本時間）→ attendance_open_digest_trigger() → EF pending-reminders に { digest: true } を送る。
--          EF が、未確認（勤怠確認漏れ）と承認待ちを集め、社長＝全店舗／チーム長＝自分のチームの店舗だけを、個人 DM で送る（0 件なら送らない）。
--  テーブルは触らない（新しい関数と、定時の実行を 1 つ足すだけ）。リマインド用の毎時の実行（pending-reminders）とは別。
-- 【止め方・戻し方】select cron.unschedule('attendance-open-digest'); drop function public.attendance_open_digest_trigger();
begin;

create or replace function public.attendance_open_digest_trigger()
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
    raise warning 'attendance_open_digest_trigger: app_secrets.notify_slack_secret が未設定';
    return;
  end if;
  select net.http_post(
    url := c_fn,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', c_anon,
      'Authorization', 'Bearer ' || c_anon,
      'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('trigger', 'pg_cron', 'digest', true),
    timeout_milliseconds := 120000
  ) into v_req;
end $$;
revoke all on function public.attendance_open_digest_trigger() from public, anon, authenticated;

-- 毎朝 9:00 JST（= 0:00 UTC）
do $$
begin
  if exists (select 1 from cron.job where jobname = 'attendance-open-digest') then
    perform cron.unschedule('attendance-open-digest');
  end if;
  perform cron.schedule('attendance-open-digest', '0 0 * * *', $cmd$select public.attendance_open_digest_trigger()$cmd$);
end $$;

commit;
