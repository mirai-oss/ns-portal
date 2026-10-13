-- 担当C: 取引先マスタの同名重複の統合（口座が同一の5グループ・14行→5行）
--
-- 【事前報告様式（DB変更）】
-- 理由: 同じ名前の取引先が重複登録されており（請求書の取込・アップロードのたびに新規登録されたため）、自動処理の重複判定・取引先の確定を妨げる。
-- 対象: 振込先の口座情報が重複どうしで完全に同じ5グループだけ（東京ガス4・東京電力エナジーパートナー4・ガーデン2・クリエイトダイザー2・リクルート2）。
--       口座が違うグループ（NTT ME・トーホーエージェンシー・Mostfun・カカクコム・野村不動産コマース）は支払方法に影響するため含めない（ユーザー確認待ち）。
-- 変更: 各グループで残す1件（既定の法人あり→請求書が多い→古い順）へ、重複側の請求書（invoices.vendor_id）を付け替え、
--       重複側の取引先は削除せず is_active=false（無効）にして notes に統合先を記録する。重複側の銀行口座は、残す側と同一内容のため無効化（is_current=false）。
--       他の表（別名・ルール・テンプレート等）に紐づくデータは、この5グループには無い（確認済み）。
-- 取り消し: 重複側は残しているので、invoices.vendor_id を戻し is_active を true に戻せば元に戻せる（下の「統合ログ」表に付け替えた請求書を記録）。
-- 既存データへの影響: 請求書の取引先IDが付け替わる（取引先の名前・金額・口座は変わらない）。
create table if not exists public.vendor_merge_log (
  id bigserial primary key, merged_at timestamptz not null default now(),
  keeper_vendor_id uuid not null, dup_vendor_id uuid not null, invoice_id uuid not null
);

-- 東京ガス: 残す=93a1ecab-ec47-45d7-ab51-94024d0cb407（請求書1件）／統合=3件
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '93a1ecab-ec47-45d7-ab51-94024d0cb407', 'a4ac9336-689b-4e8f-9870-54b38b813332', id from public.invoices where vendor_id='a4ac9336-689b-4e8f-9870-54b38b813332';
update public.invoices set vendor_id='93a1ecab-ec47-45d7-ab51-94024d0cb407', updated_at=now() where vendor_id='a4ac9336-689b-4e8f-9870-54b38b813332';
update public.vendor_bank_accounts set is_current=false where vendor_id='a4ac9336-689b-4e8f-9870-54b38b813332';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため93a1ecab-ec47-45d7-ab51-94024d0cb407に統合（2026-10-13）', updated_at=now() where id='a4ac9336-689b-4e8f-9870-54b38b813332';
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '93a1ecab-ec47-45d7-ab51-94024d0cb407', 'a8fe468f-b3ff-484d-a7fe-8ce3d2c91866', id from public.invoices where vendor_id='a8fe468f-b3ff-484d-a7fe-8ce3d2c91866';
update public.invoices set vendor_id='93a1ecab-ec47-45d7-ab51-94024d0cb407', updated_at=now() where vendor_id='a8fe468f-b3ff-484d-a7fe-8ce3d2c91866';
update public.vendor_bank_accounts set is_current=false where vendor_id='a8fe468f-b3ff-484d-a7fe-8ce3d2c91866';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため93a1ecab-ec47-45d7-ab51-94024d0cb407に統合（2026-10-13）', updated_at=now() where id='a8fe468f-b3ff-484d-a7fe-8ce3d2c91866';
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '93a1ecab-ec47-45d7-ab51-94024d0cb407', 'e5897b29-0343-42c0-aedf-e473a99c73bd', id from public.invoices where vendor_id='e5897b29-0343-42c0-aedf-e473a99c73bd';
update public.invoices set vendor_id='93a1ecab-ec47-45d7-ab51-94024d0cb407', updated_at=now() where vendor_id='e5897b29-0343-42c0-aedf-e473a99c73bd';
update public.vendor_bank_accounts set is_current=false where vendor_id='e5897b29-0343-42c0-aedf-e473a99c73bd';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため93a1ecab-ec47-45d7-ab51-94024d0cb407に統合（2026-10-13）', updated_at=now() where id='e5897b29-0343-42c0-aedf-e473a99c73bd';
-- 東京電力エナジーパートナー株式会社: 残す=3e661690-745b-4db1-9516-057d6af3e77b（請求書2件）／統合=3件
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '3e661690-745b-4db1-9516-057d6af3e77b', 'ecc43106-1746-4031-bae0-7efaf8d1d3b9', id from public.invoices where vendor_id='ecc43106-1746-4031-bae0-7efaf8d1d3b9';
update public.invoices set vendor_id='3e661690-745b-4db1-9516-057d6af3e77b', updated_at=now() where vendor_id='ecc43106-1746-4031-bae0-7efaf8d1d3b9';
update public.vendor_bank_accounts set is_current=false where vendor_id='ecc43106-1746-4031-bae0-7efaf8d1d3b9';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため3e661690-745b-4db1-9516-057d6af3e77bに統合（2026-10-13）', updated_at=now() where id='ecc43106-1746-4031-bae0-7efaf8d1d3b9';
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '3e661690-745b-4db1-9516-057d6af3e77b', '81094ac4-63ab-4783-8039-dc3f7c728d18', id from public.invoices where vendor_id='81094ac4-63ab-4783-8039-dc3f7c728d18';
update public.invoices set vendor_id='3e661690-745b-4db1-9516-057d6af3e77b', updated_at=now() where vendor_id='81094ac4-63ab-4783-8039-dc3f7c728d18';
update public.vendor_bank_accounts set is_current=false where vendor_id='81094ac4-63ab-4783-8039-dc3f7c728d18';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため3e661690-745b-4db1-9516-057d6af3e77bに統合（2026-10-13）', updated_at=now() where id='81094ac4-63ab-4783-8039-dc3f7c728d18';
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '3e661690-745b-4db1-9516-057d6af3e77b', '6fb6fb26-ba32-498d-a232-b5ecaec204ed', id from public.invoices where vendor_id='6fb6fb26-ba32-498d-a232-b5ecaec204ed';
update public.invoices set vendor_id='3e661690-745b-4db1-9516-057d6af3e77b', updated_at=now() where vendor_id='6fb6fb26-ba32-498d-a232-b5ecaec204ed';
update public.vendor_bank_accounts set is_current=false where vendor_id='6fb6fb26-ba32-498d-a232-b5ecaec204ed';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため3e661690-745b-4db1-9516-057d6af3e77bに統合（2026-10-13）', updated_at=now() where id='6fb6fb26-ba32-498d-a232-b5ecaec204ed';
-- 株式会社ガーデン: 残す=575d4a08-dfa2-4c40-bbb1-d0797fe69394（請求書2件）／統合=1件
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '575d4a08-dfa2-4c40-bbb1-d0797fe69394', '04c46dbe-8724-412e-8e0f-6e39ba1f2611', id from public.invoices where vendor_id='04c46dbe-8724-412e-8e0f-6e39ba1f2611';
update public.invoices set vendor_id='575d4a08-dfa2-4c40-bbb1-d0797fe69394', updated_at=now() where vendor_id='04c46dbe-8724-412e-8e0f-6e39ba1f2611';
update public.vendor_bank_accounts set is_current=false where vendor_id='04c46dbe-8724-412e-8e0f-6e39ba1f2611';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため575d4a08-dfa2-4c40-bbb1-d0797fe69394に統合（2026-10-13）', updated_at=now() where id='04c46dbe-8724-412e-8e0f-6e39ba1f2611';
-- 株式会社クリエイトダイザー: 残す=39d4db3c-9b7c-4c5c-88ee-38743ad3925f（請求書1件）／統合=1件
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '39d4db3c-9b7c-4c5c-88ee-38743ad3925f', '819389a1-a5c8-41b2-8ba3-6252d87e5aab', id from public.invoices where vendor_id='819389a1-a5c8-41b2-8ba3-6252d87e5aab';
update public.invoices set vendor_id='39d4db3c-9b7c-4c5c-88ee-38743ad3925f', updated_at=now() where vendor_id='819389a1-a5c8-41b2-8ba3-6252d87e5aab';
update public.vendor_bank_accounts set is_current=false where vendor_id='819389a1-a5c8-41b2-8ba3-6252d87e5aab';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため39d4db3c-9b7c-4c5c-88ee-38743ad3925fに統合（2026-10-13）', updated_at=now() where id='819389a1-a5c8-41b2-8ba3-6252d87e5aab';
-- 株式会社リクルート: 残す=a9cc5d4c-41de-4fad-b4cf-f3b5ace76d0a（請求書3件）／統合=1件
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select 'a9cc5d4c-41de-4fad-b4cf-f3b5ace76d0a', '138c89d2-ddd3-41a1-b8b0-f5e0c3874d16', id from public.invoices where vendor_id='138c89d2-ddd3-41a1-b8b0-f5e0c3874d16';
update public.invoices set vendor_id='a9cc5d4c-41de-4fad-b4cf-f3b5ace76d0a', updated_at=now() where vendor_id='138c89d2-ddd3-41a1-b8b0-f5e0c3874d16';
update public.vendor_bank_accounts set is_current=false where vendor_id='138c89d2-ddd3-41a1-b8b0-f5e0c3874d16';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のためa9cc5d4c-41de-4fad-b4cf-f3b5ace76d0aに統合（2026-10-13）', updated_at=now() where id='138c89d2-ddd3-41a1-b8b0-f5e0c3874d16';
