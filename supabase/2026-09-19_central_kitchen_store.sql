-- =====================================================================
-- セントラルキッチンをstoresへ登録 + ロケットナウ月次精算の店舗対応表に追加
-- =====================================================================
-- 背景: docs/引継ぎ書_担当D_2026-09-19.md「ロケットナウPhase2」。セントラルキッチンの
--   ロケットナウ月次精算に2026年4月分の実データ2行を検出済みだったが、delivery_store_map
--   未登録のため取込保留（Lark通知のみ）になっていた。ユーザーへ2回確認し、2026-09-19に
--   「セントラルキッチンで店舗登録してOK（経営PLも反映されるように）」と回答をもらった。
--
-- 設計: セントラルキッチンは客席のある通常の店舗ではない（調理場）ため、既存の
--   「本部」擬似店舗と同じ考え方（supabase/2026-08-22_hq_pseudo_store.sql）で
--   is_active=false の特殊な店舗行として追加する。理由:
--   - is_active=falseにしても、経営ダッシュボード側のPL集計（kd_pl_monthly_summary等の
--     リフレッシュ処理／supabase/functions/keiei-kd-refresh/index.ts）はis_activeで
--     絞り込んでいない（コード確認済み）ため、経営PLには引き続き反映される。
--   - is_active=trueで回す通常の店舗選択UI（新規予約・シフト等）には出てこないため、
--     客席のない調理場が誤って店舗ピッカーに並ぶ事故を防げる。
--   - corporation_id は同じ拠点にある「鳥一代 本店」と同じ法人（トーホーエージェンシー）を
--     そのまま引き継ぐ（docs/提案_社内情報管理システム整理_2026-09-08.md §「本店＋セントラル
--     キッチン（TOHOビル2F/3F）」の記載どおり本店と同じ建物・同じ法人という前提）。
--
-- 【delivery_store_mapのchannel_store_idについて・要フォローアップ】
--   ロケットナウの月次精算ファイル（確定値）には店舗IDが含まれず「店舗名」のみのため、
--   ns-daily-import/tasks/delivery-sales.jsのprocessSettlementBuffer()はchannel_store_name
--   で照合する（channel_store_idの実際の値は使わない）。そのため今回はプレースホルダ値
--   'central-kitchen-settlement-only'を入れている。
--   もし今後「日次（Multi）」取込（rocketnow-sales）側でセントラルキッチンの実際の
--   ロケットナウ内部店舗IDが新たに検出された場合は、buildCsv()のID照合で未登録として
--   kd_unresolved_names＋Lark通知が飛ぶので、そのとき実IDで別行を追加するか
--   （※channel_store_idが主キーの一部なので追加でよい。同じstore_idを指す複数行があっても問題ない）、
--   下記のchannel_store_id行を実IDへ更新すればよい。
--
-- 実行場所: Supabase SQL Editor（https://supabase.com/dashboard/project/uuvsxzhpxtghojoubjcc/sql/new）
--   何度実行しても壊れません（store名・delivery_store_mapのPKで重複防止済み）。
-- rollback: delete from delivery_store_map where channel='rocketnow' and channel_store_id='central-kitchen-settlement-only';
--           delete from stores where name='セントラルキッチン' and is_active=false;
-- =====================================================================

insert into public.stores (name, sort_order, is_active, corporation_id, store_no)
select
  'セントラルキッチン',
  98,
  false,
  (select corporation_id from public.stores where name = '鳥一代 本店' limit 1),
  (select coalesce(max(store_no::integer), 0) + 1 from public.stores where store_no ~ '^\d+$')::text
where not exists (select 1 from public.stores where name = 'セントラルキッチン');

insert into public.delivery_store_map (channel, channel_store_id, store_id, channel_store_name)
select 'rocketnow', 'central-kitchen-settlement-only', s.id, 'セントラルキッチン'
from public.stores s where s.name = 'セントラルキッチン'
on conflict (channel, channel_store_id) do update set
  store_id = excluded.store_id, channel_store_name = excluded.channel_store_name;

-- 確認用（実行後、下の2行がそれぞれ1件ずつ返ればOK）:
-- select id, name, is_active, corporation_id, store_no from stores where name = 'セントラルキッチン';
-- select * from delivery_store_map where channel_store_name = 'セントラルキッチン';
