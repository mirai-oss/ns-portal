-- ============================================================
-- 統合フェーズ1-b: 店舗マスタ統一（store_no 01〜12）＋ マスターフラグ
-- 対象: ハブ = 日報Supabaseプロジェクト (uuvsxzhpxtghojoubjcc)
-- 冪等: 何度実行しても安全（IF NOT EXISTS / ON CONFLICT ガード付き）
-- 既存の列・行は削除しない（追加のみ）。RLSは変更しない。
-- ============================================================

-- 1) stores に店舗番号・看板列を追加
alter table stores add column if not exists store_no text;
alter table stores add column if not exists signs text[];
create unique index if not exists stores_store_no_key
  on stores(store_no) where store_no is not null;

-- 2) 既存8店舗に店舗番号を付与（名称の揺れに備えて in で吸収）
update stores set store_no='01', signs=array['鳥一代']
  where store_no is distinct from '01' and name in ('鳥一代 本店','本店');
update stores set store_no='02', signs=array['鳥一代']
  where store_no is distinct from '02' and name in ('鳥一代 はなれ','はなれ');
update stores set store_no='03', signs=array['鳥一代']
  where store_no is distinct from '03' and name in ('芝の鳥一代','芝');
update stores set store_no='04', signs=array['鳥一代']
  where store_no is distinct from '04' and name in ('鳥一代 恵比寿','恵比寿');
update stores set store_no='05', signs=array['鳥一代']
  where store_no is distinct from '05' and name in ('鳥一代 新橋','新橋');
update stores set store_no='06', signs=array['鶏武者','匠味']
  where store_no is distinct from '06' and name in ('鶏武者 新横浜','鶏武者新横浜');
update stores set store_no='07', signs=array['鶏武者','匠味']
  where store_no is distinct from '07' and name in ('鶏武者 川崎店','鶏武者 川崎');
update stores set store_no='08', signs=array['黒霧屋','うお蔵','彩']
  where store_no is distinct from '08' and name in ('黒霧屋 新横浜','黒霧屋新横浜');

-- 3) 委託店舗 09〜12 を追加（is_active=false: 日報UIには表示されない）
insert into stores(name, sort_order, is_active, store_no, signs)
select v.name, v.sort_order, false, v.store_no, v.signs
from (values
  ('じんべぇ 川崎',   901, '09', array['じんべぇ']),
  ('じんべぇ 新横浜', 902, '10', array['じんべぇ']),
  ('エース 本厚木',   903, '11', array['横濱ホルモン会館 エース']),
  ('秋葉原 肉寿司',   904, '12', array['肉寿司'])
) as v(name, sort_order, store_no, signs)
where not exists (select 1 from stores s where s.store_no = v.store_no);

-- 4) 表記ゆれ集約テーブル（別名 → 店舗）
create table if not exists store_aliases (
  alias text primary key,
  store_id uuid not null references stores(id) on delete cascade,
  source text,                         -- どのシステム由来の表記か（メモ）
  created_at timestamptz not null default now()
);
alter table store_aliases enable row level security;
drop policy if exists store_aliases_read on store_aliases;
create policy store_aliases_read on store_aliases
  for select using (auth.uid() is not null);

insert into store_aliases(alias, store_id, source)
select v.alias, s.id, v.source
from (values
  -- 01 鳥一代 本店
  ('鳥一代 本店','01','正準'), ('本店','01','日報'),
  -- 02 はなれ
  ('鳥一代 はなれ','02','正準'), ('はなれ','02','日報'),
  -- 03 芝の鳥一代
  ('芝の鳥一代','03','正準'), ('芝','03','略称'),
  -- 04 恵比寿
  ('鳥一代 恵比寿','04','正準'), ('恵比寿','04','日報'),
  -- 05 新橋
  ('鳥一代 新橋','05','正準'), ('新橋','05','日報'),
  -- 06 鶏武者/匠味 新横浜
  ('鶏武者 新横浜','06','正準'), ('鶏武者新横浜','06','表記ゆれ'), ('匠味 新横浜','06','2枚看板'),
  -- 07 鶏武者/匠味 川崎
  ('鶏武者 川崎店','07','正準'), ('鶏武者 川崎','07','略称'), ('匠味 川崎','07','2枚看板'),
  -- 08 黒霧屋/うお蔵/彩 新横浜
  ('黒霧屋 新横浜','08','正準'), ('黒霧屋（新横浜）','08','広告シート'),
  ('黒霧屋新横浜','08','精算'), ('うお蔵','08','2枚看板'), ('彩 新横浜','08','2枚看板'),
  -- 09 じんべぇ 川崎
  ('じんべぇ 川崎','09','正準'), ('じんべえ 川崎店','09','売上シート'),
  ('川崎じんべぇ','09','精算'), ('じんべぇ川崎','09','表記ゆれ'),
  -- 10 じんべぇ 新横浜
  ('じんべぇ 新横浜','10','正準'), ('じんべえ 新横浜','10','売上シート'),
  ('新横浜じんべぇ','10','精算'),
  -- 11 エース 本厚木
  ('エース 本厚木','11','正準'), ('本厚木 エース','11','精算'),
  ('横濱ホルモン会館　エース　本厚木店','11','売上シート'),
  -- 12 秋葉原 肉寿司
  ('秋葉原 肉寿司','12','正準'), ('秋葉原　肉寿司','12','表記ゆれ'), ('肉寿司 秋葉原','12','表記ゆれ')
) as v(alias, store_no, source)
join stores s on s.store_no = v.store_no
on conflict (alias) do nothing;

-- 5) マスターアカウントフラグ（役割とは独立）
alter table users add column if not exists is_master boolean not null default false;

-- マスターにする人へ（メールアドレスを書き換えて実行）:
-- update users set is_master = true where email = 'mirai@ns0314.com';

-- 6) 確認クエリ（実行結果を目視確認する用）
-- select store_no, name, signs, is_active from stores order by store_no nulls last, sort_order;
-- select alias, s.store_no, s.name from store_aliases a join stores s on s.id=a.store_id order by s.store_no;
