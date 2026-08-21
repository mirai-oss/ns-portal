-- =====================================================================
-- 勘定科目マスタ（account_items）新設 — データ基盤Day2 タスク1
-- =====================================================================
-- 背景: 経費申請(expense_categories・6科目)とPL管理システム(GAS上の科目マスタ・
--   約38の名前付きコード)が別マスタで運用されており、正本が無い状態だった
--   （データ基盤監査レポート2026-08-21 リスクR: 勘定科目の二重管理）。
--
-- 方針: 「対応表方式」で段階移行する。PLの科目コード体系(S/F/L/R/A/O/X)を
--   正としてaccount_itemsに複製し、expense_categoriesの各科目がどのPLコードに
--   対応するかを紐付ける。既存の2マスタは一旦そのまま残し、実データは移行しない
--   （テーブル追加のみ・影響ゼロ）。
--
-- 出典: NStyle-AI/gas-backup/pl-system/コード.gs のbuildMaster()関数
--   （2026-08-21 clasp cloneで取得した本番GASコードそのまま）
-- 実行場所: Supabase SQL Editor / Management API（何度実行しても壊れません）
-- =====================================================================

create table if not exists account_items (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,              -- PL科目コード（例: L01, O03）
  name text not null,                     -- 科目名
  category text not null,                 -- S/F/L/R/A/O/X（PL管理システムの大分類）
  pl_data_source text,                    -- PL側の値の出所（'自動｜xxx' or '手入力'）
  pl_note text,                           -- PL管理システム側の備考
  expense_category_id uuid references expense_categories(id),  -- 経費申請側との対応（対応表の核心）
  sort_order int not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table account_items enable row level security;
drop policy if exists account_items_read on account_items;
create policy account_items_read on account_items for select using (auth.uid() is not null);
-- 書き込みはマスターのみ（他の管理系マスタと同じ方針）
drop policy if exists account_items_write on account_items;
create policy account_items_write on account_items for all using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.is_master)
) with check (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.is_master)
);

-- ---------------------------------------------------------------------
-- PL科目マスタを複製（本番GASの buildMaster() 準拠。プレースホルダの空き行は含めない）
-- ---------------------------------------------------------------------
insert into account_items (code, name, category, pl_data_source, pl_note, sort_order) values
  ('S01','売上','S','自動｜売上','ダッシュボード純売上を自動集計',10),
  ('S02','その他売上','S','手入力','物販・イベント等',11),
  ('F01','仕入（食材・飲料）','F','自動｜仕入','ダッシュボード仕入れを自動集計',20),
  ('L01','社員人件費','L','自動｜社員人件費','分析_日別店舗の社員給与賞与(総労働賃金+賞与)を自動集計',30),
  ('L02','アルバイト人件費（PA）','L','自動｜PA人件費','ダッシュボードから自動集計',31),
  ('L03','役員報酬','L','手入力',null,32),
  ('L04','法定福利費','L','自動｜法定福利費','分析_日別店舗の法定福利費(列AH)を自動集計',33),
  ('L05','通勤手当','L','自動｜通勤手当','分析_日別店舗の通勤手当=交通費(列AI)を自動集計',34),
  ('L06','旅費交通費','L','手入力',null,35),
  ('L07','賞与積立','L','手入力','管理会計上の引当',36),
  ('L08','退職金等','L','手入力',null,37),
  ('R01','家賃','R','手入力',null,40),
  ('R02','リース料','R','手入力',null,41),
  ('R03','家賃更新按分','R','手入力','更新料の月割',42),
  ('A01','広告宣伝費','A','自動｜広告費','DB_広告から自動集計',50),
  ('A02','販売促進費','A','手入力',null,51),
  ('O01','水道光熱費','O','手入力',null,60),
  ('O02','通信費','O','手入力',null,61),
  ('O03','消耗品・備品費','O','手入力',null,62),
  ('O04','修繕費','O','手入力',null,63),
  ('O05','衛生管理費','O','手入力',null,64),
  ('O06','カード手数料','O','手入力',null,65),
  ('O07','支払手数料','O','手入力',null,66),
  ('O08','支払報酬料','O','手入力',null,67),
  ('O09','採用教育費','O','手入力',null,68),
  ('O10','接待交際費','O','手入力',null,69),
  ('O11','会議費','O','手入力',null,70),
  ('O12','慶弔見舞費','O','手入力',null,71),
  ('O13','保険料','O','手入力',null,72),
  ('O14','租税公課','O','手入力',null,73),
  ('O15','減価償却費','O','手入力',null,74),
  ('O16','福利厚生費','O','手入力',null,75),
  ('O17','諸会費','O','手入力',null,76),
  ('O18','雑費','O','手入力',null,77),
  ('O19','本部経費（按分）','O','手入力',null,78),
  ('O20','媒体販促費（自動）','O','自動｜媒体販促','⚙設定「対象媒体」リストの純売上 × 媒体販促費率を自動計上',79),
  ('O21','運営委託費','O','手入力','★ユーザー追加科目（再構築でも保持）',80),
  ('X01','銀行返済','X','手入力','PL外（財務CF）。販管費には含まれません',90)
on conflict (code) do update set
  name = excluded.name, category = excluded.category,
  pl_data_source = excluded.pl_data_source, pl_note = excluded.pl_note,
  updated_at = now();

-- ---------------------------------------------------------------------
-- expense_categories（経費申請・6科目）との対応付け
-- ---------------------------------------------------------------------
-- 交通費 → L06 旅費交通費
update account_items set expense_category_id = (select id from expense_categories where name = '交通費')
  where code = 'L06';
-- 消耗品費 → O03 消耗品・備品費
update account_items set expense_category_id = (select id from expense_categories where name = '消耗品費')
  where code = 'O03';
-- 会議費 → O11 会議費
update account_items set expense_category_id = (select id from expense_categories where name = '会議費')
  where code = 'O11';
-- 通信費 → O02 通信費
update account_items set expense_category_id = (select id from expense_categories where name = '通信費')
  where code = 'O02';
-- 修繕費 → O04 修繕費
update account_items set expense_category_id = (select id from expense_categories where name = '修繕費')
  where code = 'O04';
-- 「その他」は1対1で決め打てないため未対応のまま残す（人が個別に判断する対応表の趣旨どおり）
