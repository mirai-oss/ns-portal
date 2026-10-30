-- =============================================================
-- Slack通知基盤 Phase 1（設計書: docs/設計書_Slack通知基盤_Phase1_2026-10-29.md）
-- 状態: ★★★ 未適用（ドラフト）★★★  ユーザー承認後に SQL Editor で適用する。
-- 方針: 既存の通知経路（Lark/Chatwork/LINE）は一切止めない。Slack を「追加の宛先」として
--       並行運用できる土台（台帳・宛先マスタ・kind=slack の受け入れ）だけを入れる。
-- 前提: users テーブルは ALTER 禁止（nippo 側の正本）→ Slack ユーザーIDは新表 user_slack に持つ。
-- =============================================================

-- -------------------------------------------------------------
-- 1. Slack チャンネルの宛先マスタ（channel_key → Slack チャンネルID）
--    channel_key はコード・設定テーブルから参照する安定したキー。Slack 側でチャンネル名を
--    変えても channel_id は変わらないので、ここを直すだけで全送信元が追従する。
-- -------------------------------------------------------------
create table if not exists slack_channels (
  channel_key      text primary key,                 -- 例: 'hq.keiri_kanshi'（英小文字・数字・ドット・アンダースコア）
  slack_channel_id text not null,                    -- 例: 'C0XXXXXXXXX'（Slack のチャンネル詳細の最下部に表示）
  display_name     text not null,                    -- 例: '#本部-経理・監視'（表示用・変わってよい）
  purpose          text,                             -- 何を流すか（人が読む説明）
  replaces         text,                             -- 置き換える旧宛先のメモ（例: 'Lark 経理チャンネル(app_secrets.cockpit_lark_webhook)'）
  is_active        boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint slack_channels_key_chk check (channel_key ~ '^[a-z0-9][a-z0-9._-]{1,63}$')
);
comment on table slack_channels is 'Slack通知の宛先マスタ。channel_key を全送信元の共通キーにする（設計書§5）';

-- Phase 1 の初期キー（slack_channel_id はユーザーがチャンネル作成後に埋める。空のままでは送信されない）
insert into slack_channels (channel_key, slack_channel_id, display_name, purpose, replaces) values
  -- 2026-10-30 ユーザー決定: 経営レポートは「一部店舗だけ見せたい人がいない」ため 3 グループを 1 つに統合し、N-Style 4 店舗だけ別チャンネル
  ('keiei.report',        'C0CDGJ7TP0R', '#経営-レポート',         '経営D 日報/週報/月報（鳥一代グループ8店: 本店・はなれ・芝・新橋・恵比寿・鶏武者川崎・鶏武者新横浜・黒霧屋新横浜）', 'Lark report_channels group1+group2+group3 (GitHub Secret LARK_WEBHOOK_GROUP1〜3) を統合'),
  ('keiei.report.nstyle', 'C0CDJDVQDC4', '#経営-レポート-nstyle',  '経営D 日報/週報/月報（N-Style 4店: じんべぇ新横浜・じんべぇ川崎・エース本厚木・秋葉原肉寿司）', '旧宛先なし（現状どのグループにも未割当。Slack化で新規に配信）'),
  ('hq.keiri_kanshi', 'C0CDEHM2T7U', '#本部-経理監視', '日次取込の結果/失敗・売上突合・請求書/入金・AI利用料・経理向け監視', 'Lark 経理チャンネル(Mac mini LARK_WEBHOOK / app_secrets.cockpit_lark_webhook)'),
  ('hq.dev_system',   'C0CD9EJ596H', '#本部-開発システム', 'GitHub Actions/Edge Function の失敗・コックピット・インフラ監視', 'Lark 監視用(app_secrets.lark_webhook_url / GitHub Secret LARK_WEBHOOK_URL)'),
  ('hq.jinji',        '', '#本部-人事・入社', '入社登録・応募・退職申請などの人事イベント（4つ目のチャンネル。不要なら hq.keiri_kanshi に寄せる）', 'Chatwork 入社通知ルーム / lark_routes 入社・応募系')
on conflict (channel_key) do nothing;

-- -------------------------------------------------------------
-- 2. 通知台帳（Slack通知1件 = 1行。notification_id を必ず持つ）
--    ボタン押下・メッセージ更新・再送・失敗リトライ・新旧並行の突合は、すべてこの行を起点にする。
-- -------------------------------------------------------------
create table if not exists notification_deliveries (
  id               uuid primary key default gen_random_uuid(),  -- = notification_id（Slack の metadata / ボタンの value に埋め込む）
  source           text not null,        -- 送信元: 'db' | 'ef:<関数名>' | 'macmini:ns-daily-import' | 'gha:<workflow>' | 'portal:<page>' | 'nippo'
  event            text not null,        -- イベント種別: 'report_daily' 'join_registered' 'import_failed' 'attendance_alert' 'task_mention' …（通知一覧の種別名に合わせる）
  channel_key      text,                 -- 宛先キー（slack_channels.channel_key）。個人DMは 'user:<users.id>'
  slack_channel_id text,                 -- 実際に送ったチャンネル/DM の ID（DMは D… で始まる）
  slack_user_id    text,                 -- 個人DMのとき相手の Slack ユーザーID
  slack_ts         text,                 -- 送信結果の message ts（更新・スレッド返信に使う）
  thread_ts        text,                 -- スレッドに付けたときの親 ts
  delivery_status  text not null default 'queued'
                   check (delivery_status in ('queued','sent','failed','updated','skipped')),
  payload          jsonb not null default '{}'::jsonb,  -- 送った本文（text/blocks）。秘密情報は入れない
  response         jsonb,                -- Slack API の応答（ok/error/ts）
  error            text,
  attempts         int not null default 0,
  dedupe_key       text,                 -- 同じ通知を二度送らないためのキー（例: 'report_daily:2026-10-29:keiei.report'）
  ref_table        text,                 -- 元レコード（例: 'hq_tasks' 'sf_attendance_alerts' 'invoices'）
  ref_id           text,
  legacy_kind      text,                 -- 並行運用の照合用: 同じ通知が旧経路でも送られたなら 'lark' | 'chatwork' | 'line'
  legacy_sent      boolean,              -- 旧経路の送信可否（分かる範囲で）
  action_state     jsonb,                -- ボタン操作の結果（例: {"confirmed_by":"<users.id>","at":"…"}）
  created_at       timestamptz not null default now(),
  sent_at          timestamptz,
  updated_at       timestamptz not null default now()
);
create unique index if not exists notification_deliveries_dedupe_uq on notification_deliveries (dedupe_key) where dedupe_key is not null;
create index if not exists notification_deliveries_event_idx on notification_deliveries (event, created_at desc);
create index if not exists notification_deliveries_channel_idx on notification_deliveries (channel_key, created_at desc);
create index if not exists notification_deliveries_ref_idx on notification_deliveries (ref_table, ref_id);
create index if not exists notification_deliveries_ts_idx on notification_deliveries (slack_channel_id, slack_ts);
comment on table notification_deliveries is 'Slack通知台帳。notification_id→channel_key→slack_channel_id→slack_ts→delivery_status を1行で保持（設計書§6）';

-- -------------------------------------------------------------
-- 3. Slack ユーザーIDの紐付け（users は ALTER 禁止のため別表）
-- -------------------------------------------------------------
create table if not exists user_slack (
  user_id         uuid primary key references users(id) on delete cascade,
  slack_user_id   text not null unique,
  matched_by      text not null default 'email' check (matched_by in ('email','manual')),
  matched_email   text,                  -- 照合に使ったメール（小文字）
  matched_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on table user_slack is 'users.id ↔ Slack ユーザーID。users:read.email で自動照合（設計書§9）。Phase 3 の個人DMで使う';

-- -------------------------------------------------------------
-- 4. RLS: 台帳・宛先マスタ・紐付けは service_role（Edge Function）だけが書く。
--    閲覧は本部（CEO/HQ）のみ（運用画面・突合用）。
-- -------------------------------------------------------------
alter table slack_channels          enable row level security;
alter table notification_deliveries enable row level security;
alter table user_slack              enable row level security;

drop policy if exists slack_channels_hq_read on slack_channels;
create policy slack_channels_hq_read on slack_channels for select using (
  exists (select 1 from users u where u.id = auth.uid() and (u.role in ('CEO','HQ') or u.is_master))
);
drop policy if exists notification_deliveries_hq_read on notification_deliveries;
create policy notification_deliveries_hq_read on notification_deliveries for select using (
  exists (select 1 from users u where u.id = auth.uid() and (u.role in ('CEO','HQ') or u.is_master))
);
drop policy if exists user_slack_self_or_hq_read on user_slack;
create policy user_slack_self_or_hq_read on user_slack for select using (
  user_id = auth.uid() or exists (select 1 from users u where u.id = auth.uid() and (u.role in ('CEO','HQ') or u.is_master))
);
-- 書き込みポリシーは作らない（= authenticated からは書けない。service_role は RLS をバイパス）

-- -------------------------------------------------------------
-- 5. 既存の設定テーブルに kind='slack' を受け入れさせる
--    Phase 1 のルール: kind='slack' の行は「Webhook URL/ルームIDの列に channel_key を入れる」
--    （呼び出し側の関数を一切変えずに済ませるため。列名の付け替えは全移行後に検討）
-- -------------------------------------------------------------
-- 5-1. 本部タスク通知チャンネル（kind 制約を拡張）
alter table hq_notify_channels drop constraint if exists hq_notify_channels_kind_check;
alter table hq_notify_channels add constraint hq_notify_channels_kind_check
  check (kind in ('lark_webhook','inapp','chatwork','slack'));
comment on column hq_notify_channels.room_id is 'chatwork: ルームID ／ slack: channel_key（slack_channels）';

-- 5-2. nippo の配信先（lark_routes.kind）と 経営レポート（report_channels.kind）には check 制約が無い
--      （kind は text・既定 'lark'）。slack 行の宛先は次の列に入れる:
--        lark_routes.webhook_url      ← channel_key
--        report_channels.secret_name  ← channel_key（kind='slack' のとき。GitHub Secret 名ではなくなる）
--      誤登録を防ぐため、値の形だけ検証する制約を付ける。
alter table lark_routes drop constraint if exists lark_routes_slack_target_chk;
alter table lark_routes add constraint lark_routes_slack_target_chk
  check (kind <> 'slack' or (webhook_url ~ '^[a-z0-9][a-z0-9._-]{1,63}$' or webhook_url ~ '^user:[0-9a-f-]{36}$'));
alter table report_channels drop constraint if exists report_channels_slack_target_chk;
alter table report_channels add constraint report_channels_slack_target_chk
  check (kind <> 'slack' or secret_name ~ '^[a-z0-9][a-z0-9._-]{1,63}$');

-- 5-3. 経営レポートの配信マトリクス（GitHub Actions が読む）に channel_key を出す
create or replace view public.report_channel_matrix_v as
select
  rc.id,
  rc.name as "group",
  rc.kind,
  rc.secret_name,
  rc.chatwork_room_id,
  rc.keyword,
  rc.report_kinds,
  case when rc.kind = 'slack' then rc.secret_name end as channel_key,
  string_agg(s.name || '|' || coalesce(s.file_key, ''), ',' order by rcs.sort_order, s.sort_order) as stores
from public.report_channels rc
join public.report_channel_stores rcs on rcs.channel_id = rc.id
join public.stores s on s.id = rcs.store_id
where rc.is_active and s.is_active
group by rc.id, rc.name, rc.kind, rc.secret_name, rc.chatwork_room_id, rc.keyword, rc.report_kinds
order by rc.sort_order;
grant select on public.report_channel_matrix_v to anon;

-- -------------------------------------------------------------
-- 6. DB からの送信口: notify_route_send に kind='slack' を追加
--    本番の現行定義は supabase/restored/2026-10-29_notify_functions_prod_snapshot.sql（無改変）。
--    変更点は「slack 分岐の追加」だけ。lark / chatwork の分岐は現行と同一にする（適用前に diff で確認）。
--    Slack の Bot Token は DB に置かない。DB は app_secrets.notify_slack_secret（内部合言葉）だけで
--    Edge Function notify-slack を呼び、実送信は notify-slack が行う。
-- -------------------------------------------------------------
create or replace function public.notify_route_send(p_kind text, p_target text, p_text text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'net', 'extensions'
as $function$
declare v_token text; v_secret text; v_id uuid;
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/smaregi-sync';
  c_slack constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/notify-slack';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  c_key  constant text := (select value from app_secrets where key = 'checklist_intake_secret');
begin
  if p_target is null or length(trim(p_target)) = 0 then return; end if;
  begin
    if p_kind = 'slack' then
      -- 2026-10-29 追加（Slack移行 Phase 1）。p_target = channel_key（または 'user:<users.id>'）
      select value into v_secret from app_secrets where key = 'notify_slack_secret';
      if v_secret is null or length(trim(v_secret)) = 0 then
        insert into lark_log(ok, message, detail) values (false, left(p_text,300), 'Slack: notify_slack_secret 未設定');
        return;
      end if;
      -- 台帳に先に積む（queued）。notification_id を Edge Function に渡し、送信結果は向こうが同じ行を更新する
      insert into notification_deliveries(source, event, channel_key, payload)
        values ('db', coalesce(nullif(current_setting('ns.notify_event', true), ''), 'route'), trim(p_target),
                jsonb_build_object('text', p_text))
        returning id into v_id;
      perform net.http_post(
        url := c_slack,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'apikey', c_anon,
          'Authorization', 'Bearer ' || c_anon,
          'x-notify-secret', trim(v_secret)),
        body := jsonb_build_object(
          'action', 'send',
          'notification_id', v_id,
          'channel_key', trim(p_target),
          'text', p_text,
          'source', 'db')
      );
    elsif p_kind = 'chatwork' then
      select value into v_token from app_secrets where key = 'chatwork_token';
      if v_token is null or length(trim(v_token)) = 0 then
        insert into lark_log(ok, message, detail) values (false, left(p_text,300), 'Chatworkのトークン未設定');
        return;
      end if;
      -- Edge Function に中継（実際の送信結果は Edge Function 側が lark_log に記録する）
      perform net.http_post(
        url := c_fn,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'apikey', c_anon,
          'Authorization', 'Bearer ' || c_anon),
        body := jsonb_build_object(
          'action', 'notify_chatwork',
          'secret', c_key,
          'room', trim(p_target),
          'text', p_text,
          'token', trim(v_token))
      );
    else
      perform net.http_post(
        url := trim(p_target),
        headers := '{"Content-Type":"application/json"}'::jsonb,
        body := jsonb_build_object('msg_type','text','content',jsonb_build_object('text',p_text))
      );
      insert into lark_log(ok, message, detail) values (true, left(p_text,300), 'Lark');
    end if;
  exception when others then
    insert into lark_log(ok, message, detail) values (false, left(p_text,300), SQLERRM);
  end;
end $function$;

-- -------------------------------------------------------------
-- 7. 本部タスクの通知関数（hq_notify_step_event / hq_notify_comment / hq_notify_task_urgent / hq_check_alerts）
--    は `c.kind in ('lark_webhook','chatwork')` で宛先を絞っている。Phase 1-c（TK-246）で
--    `('lark_webhook','chatwork','slack')` に広げる。4関数とも長いため、このファイルには含めず、
--    スナップショットから diff 最小で別ファイル（2026-11-xx_hq_notify_slack.sql）にする。
-- -------------------------------------------------------------

-- 確認用:
-- select * from slack_channels order by channel_key;
-- select delivery_status, count(*) from notification_deliveries group by 1;
-- select pg_get_functiondef('public.notify_route_send(text,text,text)'::regprocedure);
