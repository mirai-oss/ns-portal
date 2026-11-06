-- =============================================================
-- Google口コミ Supabase直結化 ②（2026-11-06）: 毎朝の自動取得を Supabase 内（pg_cron + pg_net）で完結させる
--   前提: Supabase 管理画面で Cron（pg_cron）を有効化済み（手順は設計書 §9）。pg_net は導入済み（0.20.4）。
--   毎日 23:00 UTC = 08:00 JST に Edge Function google-reviews-fetch（op=fetch）を呼ぶ。
--   日報 12:00 JST・経営ダッシュボードの朝反映 08:45 より前に終わる（12 掲載で約 10 秒）。
--   合言葉は app_secrets.notify_slack_secret（既存。notify_route_send と同じ）を x-notify-secret で渡す。SQL に秘密は書かない。
--   適用: python3 scripts/apply_sql.py supabase/2026-11-06_google_reviews_cron.sql
--   止めるとき: select cron.unschedule('google-reviews-daily');
-- =============================================================
create extension if not exists pg_cron;

create or replace function public.google_reviews_fetch_trigger()
returns void
language plpgsql
security definer
set search_path to 'public', 'net', 'extensions'
as $function$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/google-reviews-fetch';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_req bigint;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then
    raise warning 'google_reviews_fetch_trigger: app_secrets.notify_slack_secret が未設定';
    return;
  end if;
  select net.http_post(
    url := c_fn,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'apikey', c_anon,
      'Authorization', 'Bearer ' || c_anon,
      'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'fetch', 'trigger', 'pg_cron'),
    timeout_milliseconds := 120000
  ) into v_req;
end $function$;
revoke all on function public.google_reviews_fetch_trigger() from public, anon, authenticated;

-- 同名ジョブがあれば置き換える
do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'google-reviews-daily';
exception when others then null;
end $$;
select cron.schedule('google-reviews-daily', '0 23 * * *', $$select public.google_reviews_fetch_trigger()$$);
