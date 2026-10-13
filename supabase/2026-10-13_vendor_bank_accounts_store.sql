-- 担当C: 取引先の銀行口座を「店舗ごと」に持てるようにする（野村不動産コマースの新横浜・川崎で口座が違う件）
--
-- 【事前報告様式（DB変更）】
-- 理由: 野村不動産コマースは、新横浜（鶏武者 新横浜）と川崎（鶏武者 川崎店）の分で請求書が毎月2つ来て、口座も別（8031／3712）。
--       現状は「1取引先につき現在有効な口座は1件だけ」(vba_current_unique)のため、片方が過去口座扱いになり、口座確認が警告になる・振込先が1件に固定される。
-- 現構造: vendor_bank_accounts は取引先ごとに is_current=true が高々1件（部分ユニーク索引 vba_current_unique(vendor_id) where is_current）。店舗の列は無い。
-- 変更（追加と索引の置き換えのみ。既存の行・列は変更しない）:
--   vendor_bank_accounts に store_id（任意・stores参照）を追加。NULL=従来どおり取引先全体の口座。店舗を指定した口座は、その店舗の請求書に使う。
--   部分ユニーク索引を (vendor_id, 店舗) ごとに現在有効1件へ置き換え（店舗NULLの取引先全体の口座も従来どおり1件）。
--   データ: 野村不動産コマースの2口座を設定: 口座8031(東京営業部)=鶏武者 新横浜、口座3712(ビジネス営業部)=鶏武者 川崎店。両方を現在有効にする。
-- 既存データへの影響: 野村不動産コマース以外は変化なし（store_idはNULLのまま）。選び方は「請求書の店舗の口座→無ければ店舗NULLの口座」で、従来の取引先は今までと同じ口座が選ばれる。
-- migration: 何度流しても壊れない。 rollback: drop index vba_current_per_store_uk; update vendor_bank_accounts set store_id=null where store_id is not null; （野村の2件はis_currentを1件に戻す）; create unique index vba_current_unique on vendor_bank_accounts(vendor_id) where is_current;
alter table public.vendor_bank_accounts add column if not exists store_id uuid references public.stores(id) on delete set null;

drop index if exists public.vba_current_unique;
create unique index if not exists vba_current_per_store_uk
  on public.vendor_bank_accounts (vendor_id, coalesce(store_id, '00000000-0000-0000-0000-000000000000'::uuid)) where is_current;

-- 野村不動産コマース: 新横浜=8031 / 川崎=3712（請求書4件の店舗と口座の対応から確認済み）
update public.vendor_bank_accounts b set store_id = (select id from public.stores where name = '鶏武者 新横浜' limit 1)
  where b.id = '0bca01a2-f043-45b8-b08f-0a9eb9eb58f9';
update public.vendor_bank_accounts b set store_id = (select id from public.stores where name = '鶏武者 川崎店' limit 1)
  where b.id = '961c6260-b360-44a6-8cb8-d45036f41d31';
update public.vendor_bank_accounts set is_current = true, valid_to = null
  where id = '0bca01a2-f043-45b8-b08f-0a9eb9eb58f9';
