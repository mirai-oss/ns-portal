-- 業務委託精算書自動連携(A-10)拡張: 「運営委託費の自動連携」と「勘定科目ベースの経費PL自動連携」を
-- 別々にON/OFFできるようにする。
--
-- 背景: 従来はstores.seisan_targetという単一フラグが、tori-dashboardのsyncSeisanFeeToPl（運営委託費）と
-- syncSeisanCategoriesToPl（精算書明細の勘定科目ベース）の両方の対象店舗を兼用で決めていた。
-- ユーザー要望: 「新横浜　黒霧屋は運営委託費の自動連携は対象外のままでよいが、精算書内の個別経費は
-- PL反映対象の勘定科目にチェックが入っていれば反映されるようにしてほしい」→ 単一フラグでは表現できないため分離する。
--
-- 新カラムseisan_pl_categories_targetを追加し、既存店舗は現状のseisan_targetの値をそのまま引き継ぐ
-- （＝新カラム導入によって秋葉原肉寿司・じんべぇ川崎・じんべぇ新横浜・エース本厚木の挙動は一切変わらない）。
-- 黒霧屋 新横浜だけ、この新カラムをtrueにしてseisan_targetはfalseのまま維持する。

alter table stores add column if not exists seisan_pl_categories_target boolean;

-- 既存店舗は現状のseisan_targetの値をそのまま引き継ぐ（新規追加行のみ更新・二重実行しても安全）
update stores set seisan_pl_categories_target = seisan_target where seisan_pl_categories_target is null;

alter table stores alter column seisan_pl_categories_target set default false;
alter table stores alter column seisan_pl_categories_target set not null;

comment on column stores.seisan_target is
  '業務委託精算書の運営委託費(syncSeisanFeeToPl)自動連携の対象店舗かどうか。勘定科目ベースの経費連携は
   seisan_pl_categories_targetを見る(2026-09-05分離)。';
comment on column stores.seisan_pl_categories_target is
  '業務委託精算書の明細(勘定科目が付いたもの)を店舗PLへ自動連携(syncSeisanCategoriesToPl)する対象店舗かどうか。
   運営委託費の自動連携(seisan_target)とは独立に設定できる(2026-09-05追加。黒霧屋 新横浜のように
   運営委託費は対象外だが個別経費のPL反映は対象にしたい、というケースに対応するため)。';

-- store_directory_vへ新カラムを追加（既存の列・並び順は維持。CREATE OR REPLACEなので破壊的変更ではない）
create or replace view store_directory_v as
 select s.id,
    s.store_no,
    s.name,
    s.signs,
    c.name as corporation_name,
    s.sort_order,
    s.is_active,
    s.weather_lat,
    s.weather_lon,
    s.seisan_target,
    s.file_key,
    coalesce(( select jsonb_agg(jsonb_build_object('alias', a.alias, 'kind', a.kind, 'source', a.source) order by a.alias)
           from store_aliases a
          where a.store_id = s.id), '[]'::jsonb) as aliases,
    s.seisan_store_name,
    s.seisan_pl_categories_target
   from stores s
     left join corporations c on c.id = s.corporation_id;

-- 黒霧屋 新横浜: 運営委託費の自動連携は対象外のまま、勘定科目ベースの経費PL自動連携だけ有効にする
update stores set seisan_pl_categories_target = true where name = '黒霧屋 新横浜';
