-- 2026-10-16 店舗の「運営会社」（info.stores.operator_name）
-- ユーザー要望: N-Styleの物件・契約で、運営会社が表示される所とされない所があるため、精算書の支払先を元に全店舗で表示する。
-- 契約の借主（法人）と店舗の運営会社が違う場合がある（例: 黒霧屋＝借主N-Style・運営トーホー／じんべぇ・エース＝運営 株式会社Mostfun）。
-- 冪等。既存の列・データは変更しない（列追加と、運営会社が空の店舗への値の投入のみ）。
alter table info.stores add column if not exists operator_name text;
comment on column info.stores.operator_name is '店舗を運営している会社（正式名称）。賃貸借契約の借主・所属法人と違う場合に表示する。精算書の支払先などを根拠に設定。';

-- 精算書（seisan_statement_rules）の支払先・店舗の運営実態にもとづく初期値（空の店舗だけ）
update info.stores set operator_name = '株式会社Mostfun'          where store_code in ('09','10','11') and operator_name is null;
update info.stores set operator_name = '有限会社トーホーエージェンシー' where store_code = '08'              and operator_name is null;
update info.stores set operator_name = '株式会社FAM Dining'        where store_code = '12'              and operator_name is null;
