-- 担当C: 取引先マスタの同名重複の再発防止（DB側の最後の砦）
--
-- 【事前報告様式（DB変更）】
-- 理由: 請求書の取込・アップロードのたびに同名の取引先が新規登録され重複していた（2026-10-13に29行→統合）。
--       画面・Edge Function（vendor-master upsert_vendor）側で既存を再利用するようにしたが、同時登録などをすり抜けても
--       DBが同名の有効な取引先を2件作らせないようにする。
-- 現構造: vendors.name に一意制約は無い。統合後、有効な取引先の同名重複は0件（確認済み）。
-- 変更: 部分ユニーク索引を1つ追加（有効な取引先の name は1件だけ。無効にした取引先は対象外＝統合で無効にした行は影響なし）。既存データ・列は変更しない。
-- 既存データへの影響: なし（重複0件のため索引を作れる）。 migration: 何度流しても壊れない。 rollback: drop index vendors_active_name_uk;
create unique index if not exists vendors_active_name_uk on public.vendors (name) where is_active;
