-- =============================================================
-- Slack通知基盤 Phase 1-a（TK-244）: nippo の通知ルート（lark_routes）に Slack を追加（2026-10-30）
-- 設計: docs/設計書_Slack通知基盤_Phase1_2026-10-29.md §5/§7
-- 方針: 既存の Lark/Chatwork 行は触らない。Slack 行は同じ events で複製し、まず is_active=false で登録。
--       ユーザーがチャンネルを作って slack_channels.slack_channel_id が入った後に is_active=true にする（並行運用開始）。
-- 戻し方: delete from lark_routes where kind='slack';
--         alter table lark_routes drop constraint lark_routes_kind_check;
--         alter table lark_routes add constraint lark_routes_kind_check check (kind in ('lark','chatwork'));
-- =============================================================

-- 1. 種別チェックに slack を追加（Phase 1 SQL で漏れていた）
alter table public.lark_routes drop constraint if exists lark_routes_kind_check;
alter table public.lark_routes add constraint lark_routes_kind_check
  check (kind in ('lark', 'chatwork', 'slack'));

-- 2. 宛先マスタ: 人事・採用（入社通知＋求人応募＋応募者メッセージを 1 部屋に）／役員チームの日報（新規キー）
update public.slack_channels
   set display_name = '#本部-人事・採用',
       purpose = '入社登録（Chatwork 入社通知）・求人応募（求人応募通知）・応募者からの LINE メッセージ（求人メッセージ通知）',
       replaces = 'Chatwork 3 ルーム: 入社通知 / 求人応募通知 / 求人メッセージ通知（lark_routes）',
       updated_at = now()
 where channel_key = 'hq.jinji';
insert into public.slack_channels (channel_key, slack_channel_id, display_name, purpose, replaces)
values ('keiei.team_report', '', '#経営-チーム日報', 'チーム長（役員チーム）の日報本文（nippo report_daily・role=TEAM）', 'Lark「役員チームの日報」グループ（lark_routes）')
on conflict (channel_key) do nothing;

-- 3. Slack 行を複製（is_active=false）。name は「<元の名前>（Slack）」で一覧上の区別をつける
insert into public.lark_routes (name, kind, webhook_url, role, team_id, store_id, kinds, events, is_active, sort_order)
select lr.name || '（Slack）', 'slack',
       case when lr.events && array['join_registered','applicant_new','applicant_message'] then 'hq.jinji'
            when lr.events && array['report_daily'] then 'keiei.team_report' end,
       lr.role, lr.team_id, lr.store_id, lr.kinds, lr.events, false, lr.sort_order
  from public.lark_routes lr
 where lr.is_active and lr.kind in ('lark','chatwork')
   and lr.name in ('入社通知', '求人応募通知', '求人メッセージ通知', '役員チームの日報')
   and not exists (select 1 from public.lark_routes x where x.kind = 'slack' and x.name = lr.name || '（Slack）');
-- 「中山通知専用」（個人向け: task_assigned/report_comment/report_like/chat_message）は Phase 3 の個人 DM（user:<id>）で扱うため今回は複製しない

-- 4. テスト送信ボタン（nippo）の返答文に Slack を追加。本番スナップショット（restored/…）との差分はこの case 1 行だけ
CREATE OR REPLACE FUNCTION public.lark_route_test(p_route uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare r lark_routes%rowtype;
begin
  if not exists(select 1 from users where id = auth.uid() and role in ('CEO','HQ')) then
    raise exception '権限がありません（社長・本部のみ）';
  end if;
  select * into r from lark_routes where id = p_route;
  if not found then raise exception '設定が見つかりません'; end if;
  perform notify_route_send(r.kind, r.webhook_url,
    '🐔【テスト】「' || r.name || '」の送信先として設定されています');
  return case when r.kind = 'chatwork'
    then 'Chatworkへ送信しました（数秒かかります）。届かない場合は設定画面の送信ログをご確認ください'
    when r.kind = 'slack'
    then 'Slackへ送信しました（数秒かかります）。届かない場合はポータルの通知台帳（notification_deliveries）をご確認ください'
    else 'Larkへ送信しました。グループを確認してください' end;
end $function$;
