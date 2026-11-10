-- 2026-11-12 担当A（TK-252）: 店舗別 Slack 日報チャンネル（鳥一代グループ8店）の配信設定。★草案・未適用・ユーザー承認と各チャンネルIDの提供後に適用★
-- 方針（設計書 §2.5・確定）: 日報カードは店舗別チャンネルへ。#経営-レポート(keiei.report)には 全店比較サマリ・週報・月報だけを残す（日報は外す）。
--   Lark group1〜3・Chatwork・nippo 役員日報の停止は「店舗別配信が3日連続成功した翌日にユーザー承認後」＝本SQLの対象外（別SQL）。
-- 段階: ①チャンネル行の登録（is_active=false・IDは空）→ ②Slackでチャンネルを作成し、ユーザー提供のIDを投入 → ③有効化（is_active=true）→ ④ドライラン/テスト配信（ユーザー承認）→ ⑤本配信開始時に keiei.report から daily を外す。
-- 【rollback】delete from report_channel_stores / report_channels（name like 'slack_store_%'）、delete from slack_channels（channel_key like 'store.%'）、update report_channels set report_kinds='{daily,weekly,monthly}' where name='slack_tori'。
-- 対象8店（stores.file_key）: honten, hanare, shiba, shinbashi, ebisu, torimusha-kawasaki, torimusha-shinyoko, kurokiriya-shinyoko

-- ① 宛先マスタ（ID は空＝未設定。ユーザーがチャンネルを作成後に ② で投入。このファイルや文書にIDを書かない＝SQL実行時にだけ入れる）
insert into public.slack_channels (channel_key, slack_channel_id, display_name, purpose, replaces, is_active) values
  ('store.honten',              '', '#日報-鳥一代本店',     '店舗別 日報カード（画像）', '', false),
  ('store.hanare',              '', '#日報-鳥一代はなれ',   '店舗別 日報カード（画像）', '', false),
  ('store.shiba',               '', '#日報-芝の鳥一代',     '店舗別 日報カード（画像）', '', false),
  ('store.shinbashi',           '', '#日報-鳥一代新橋',     '店舗別 日報カード（画像）', '', false),
  ('store.ebisu',               '', '#日報-鳥一代恵比寿',   '店舗別 日報カード（画像）', '', false),
  ('store.torimusha-kawasaki',  '', '#日報-鶏武者川崎',     '店舗別 日報カード（画像）', '', false),
  ('store.torimusha-shinyoko',  '', '#日報-鶏武者新横浜',   '店舗別 日報カード（画像）', '', false),
  ('store.kurokiriya-shinyoko', '', '#日報-黒霧屋新横浜',   '店舗別 日報カード（画像）', '', false)
on conflict (channel_key) do nothing;

-- ① 配信先（kind=slack・secret_name=channel_key・日報のみ・1店舗ずつ・無効のまま）
insert into public.report_channels (name, kind, secret_name, report_kinds, is_active, sort_order)
select 'slack_store_' || s.file_key, 'slack', 'store.' || s.file_key, array['daily']::text[], false, 20 + row_number() over (order by s.sort_order)
from public.stores s where s.file_key in ('honten','hanare','shiba','shinbashi','ebisu','torimusha-kawasaki','torimusha-shinyoko','kurokiriya-shinyoko')
  and not exists (select 1 from public.report_channels c where c.name = 'slack_store_' || s.file_key);
insert into public.report_channel_stores (channel_id, store_id, sort_order)
select c.id, s.id, 1 from public.report_channels c join public.stores s on c.name = 'slack_store_' || s.file_key
where not exists (select 1 from public.report_channel_stores x where x.channel_id = c.id and x.store_id = s.id);

-- ② チャンネルID投入（ユーザー提供値を、実行時にだけ書き換えて実行。例）
--   update public.slack_channels set slack_channel_id = '<ユーザー提供のID>' where channel_key = 'store.honten';
-- ③ 有効化（IDが入った店舗から順に）
--   update public.slack_channels set is_active = true where channel_key like 'store.%' and slack_channel_id <> '';
--   update public.report_channels set is_active = true where name like 'slack_store_%' and secret_name in (select channel_key from public.slack_channels where is_active and slack_channel_id <> '');
-- ⑤ 本配信開始（ユーザー承認後）: #経営-レポートから日報カードを外す（全店比較サマリ・週報・月報は残す）
--   update public.report_channels set report_kinds = array['weekly','monthly']::text[] where name = 'slack_tori';

-- 確認用SELECT
--   select c.name, c.kind, c.secret_name, c.report_kinds, c.is_active, (select count(*) from public.report_channel_stores x where x.channel_id = c.id) stores from public.report_channels c where c.kind = 'slack' order by c.sort_order;
--   select channel_key, display_name, (slack_channel_id <> '') has_id, is_active from public.slack_channels where channel_key like 'store.%' order by 1;
