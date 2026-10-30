-- =============================================================
-- Slack通知基盤 Phase 1-b（TK-245）: 経営レポートの配信先に Slack を追加（2026-10-30）
-- 設計: docs/設計書_Slack通知基盤_Phase1_2026-10-29.md §5/§7/§16
-- ユーザー決定（2026-10-30）: 旧 Lark 3 グループ（group1〜3）は「一部店舗だけ見せたい人がいない」ため
--   Slack では 1 つ（keiei.report＝鳥一代グループ 8 店）に統合し、N-Style 4 店は keiei.report.nstyle に分ける。
-- 既存の group1〜3（Lark）は触らない（14 日間の並行運用。停止は TK-247 で is_active=false にする）。
-- 戻し方: delete from report_channel_stores where channel_id in (select id from report_channels where kind='slack');
--         delete from report_channels where kind='slack';
-- =============================================================

-- 1. 種別チェックに slack を追加（Phase 1 SQL では slack_target_chk だけ追加していて kind_check は未対応だった）
alter table public.report_channels drop constraint if exists report_channels_kind_check;
alter table public.report_channels add constraint report_channels_kind_check
  check (kind in ('lark', 'chatwork', 'slack'));

-- 2. Slack の配信グループ 2 行（secret_name 列に channel_key を入れる＝workflow 側の変更なしで matrix に乗る）
insert into public.report_channels (name, kind, secret_name, report_kinds, is_active, sort_order)
values
  ('slack_tori',   'slack', 'keiei.report',        array['daily','weekly','monthly'], true, 11),
  ('slack_nstyle', 'slack', 'keiei.report.nstyle', array['daily','weekly','monthly'], true, 12)
on conflict (name) do nothing;

-- 3. 店舗割当（名前で引く。該当店舗が無ければその行は入らない＝後で件数を確認する）
insert into public.report_channel_stores (channel_id, store_id, sort_order)
select rc.id, s.id, x.ord
from (values
  ('slack_tori',   '鳥一代 本店',   1), ('slack_tori', '鳥一代 はなれ', 2), ('slack_tori', '芝の鳥一代', 3), ('slack_tori', '鳥一代 新橋', 4),
  ('slack_tori',   '鳥一代 恵比寿', 5), ('slack_tori', '鶏武者 川崎店', 6), ('slack_tori', '鶏武者 新横浜', 7), ('slack_tori', '黒霧屋 新横浜', 8),
  ('slack_nstyle', 'じんべぇ 新横浜', 1), ('slack_nstyle', 'じんべぇ 川崎', 2), ('slack_nstyle', 'エース 本厚木', 3), ('slack_nstyle', '秋葉原 肉寿司', 4)
) as x(ch, store, ord)
join public.report_channels rc on rc.name = x.ch
join public.stores s on s.name = x.store and s.is_active
where not exists (select 1 from public.report_channel_stores e where e.channel_id = rc.id and e.store_id = s.id);
