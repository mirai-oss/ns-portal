-- =============================================================
-- 2026-11-08 従業員と Slack の紐づけ（招待・自動紐づけ・手動紐づけ・一覧表示）
-- ユーザー指示: 「従業員情報から Slack を招待。登録した時点で管理システムに紐づけ、どの人がどの Slack か分かるように（スマレジ連携と同じ理屈）。
--               一覧に LINE のようにアイコン、『未連携・未提出だけ探す』で Slack 未連携も探せるように」
-- 方針（ユーザー 2026-11-08）: 入社前は LINE、入社後は Slack。Slack の紐づけはメール一致の自動方式（後で入社案内の画面にも組み込める）。
-- 仕組み:
--   user_slack（既存: user_id ↔ slack_user_id・matched_by email）に slack_name を追加。読める範囲を「ログインしている人なら誰でも」に広げる（Slack の ID と表示名は秘密ではない。一覧の目印に使う）
--   app_settings 'slack_invite' = {"url": "<Slack の招待リンク>", "note": ...}（CEO/HQ/マスターが EF slack-link op=set_invite で保存）
--   slack_invite_log: 誰にいつ招待を送ったか（LINE で送った／リンクをコピーした）
--   EF slack-link（JWT: CEO/HQ/マスター）: sync（メール照合）/ members（Slack メンバー一覧）/ invite（LINE で招待を送る）/ link（手で紐づけ）/ unlink / set_invite
--   EF slack-events（Slack Events API）: team_join・user_change でメール照合して即紐づけ（Slack アプリ側で Event Subscriptions の設定が要る＝手順書）
--   pg_cron slack-link-sync: 毎日 09:30 JST に全員照合（イベントを取りこぼしても翌朝には紐づく）
-- =============================================================

alter table public.user_slack add column if not exists slack_name text;
alter table public.user_slack add column if not exists slack_display_name text;
comment on column public.user_slack.matched_by is 'email=メール一致（照合）/ team_join=Slack 参加イベントでメール一致 / manual=本部が手で紐づけ';

drop policy if exists user_slack_read_authenticated on public.user_slack;
create policy user_slack_read_authenticated on public.user_slack for select to authenticated using (true);

create table if not exists public.slack_invite_log (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users(id) on delete cascade,
  sent_by    uuid references public.users(id),
  channel    text not null check (channel in ('line', 'copy')),   -- line=LINE で招待リンクを送った / copy=リンクをコピーして手渡し
  sent_at    timestamptz not null default now(),
  note       text
);
create index if not exists slack_invite_log_user_idx on public.slack_invite_log (user_id, sent_at desc);
alter table public.slack_invite_log enable row level security;
drop policy if exists slack_invite_log_read on public.slack_invite_log;
create policy slack_invite_log_read on public.slack_invite_log for select to authenticated using (true);

-- 毎日の照合（EF slack-link op=sync を x-notify-secret で呼ぶ。google_reviews_fetch_trigger と同じ作り）
create or replace function public.slack_link_sync_trigger()
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
  if v_secret is null or length(trim(v_secret)) = 0 then
    raise warning 'slack_link_sync_trigger: app_secrets.notify_slack_secret が未設定';
    return;
  end if;
  select net.http_post(
    url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'sync', 'trigger', 'pg_cron'),
    timeout_milliseconds := 60000
  ) into v_req;
end $$;
revoke all on function public.slack_link_sync_trigger() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'slack-link-sync') then perform cron.unschedule('slack-link-sync'); end if;
  perform cron.schedule('slack-link-sync', '30 0 * * *', $cmd$select public.slack_link_sync_trigger()$cmd$);   -- 09:30 JST
end $$;
