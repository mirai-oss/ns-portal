-- =============================================================
-- 2026-11-08 Slack 未連携の本人へ自動で再送（ユーザー決定: 招待から 3 日で再送 → 以後 1 週間おき → 最大 3 回。LINE＋メール）
--   slack_invite_log.resend_no: 0=最初の招待 / 1〜3=再送の回数。EF slack-link op=remind_employees が毎日 10:00 JST に判定して送る。
--   3 回送っても未連携の人は、管理側の朝の一覧（op=remind）で「要フォロー」に分けて出す。
-- =============================================================
alter table public.slack_invite_log add column if not exists resend_no int not null default 0;

create or replace function public.slack_remind_employees_trigger()
returns void
language plpgsql
security definer
set search_path to 'public', 'net', 'extensions'
as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/slack-link';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_req bigint;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'slack_remind_employees_trigger: notify_slack_secret 未設定'; return; end if;
  select net.http_post(
    url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'remind_employees', 'trigger', 'pg_cron'),
    timeout_milliseconds := 120000
  ) into v_req;
end $$;
revoke all on function public.slack_remind_employees_trigger() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'slack-link-remind-employees') then perform cron.unschedule('slack-link-remind-employees'); end if;
  perform cron.schedule('slack-link-remind-employees', '0 1 * * *', $cmd$select public.slack_remind_employees_trigger()$cmd$);   -- 10:00 JST（管理側リマインド 09:45 の後）
end $$;
