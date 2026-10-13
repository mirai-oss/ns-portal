-- 担当C: 取引先マスタの同名重複の統合（口座・支払方法が違う5グループ）
--
-- 【事前報告様式（DB変更）】
-- 理由: ユーザー判断「支払方法が違っても取引先としては同じ。請求書が2枚に分かれて来ることがあり、それは重複ではない。取引先ベースではなく請求書ベースで確認して分ける」。
-- 対象: NTT ME・有限会社トーホーエージェンシー・Mostfun・カカクコム・野村不動産コマース（口座や支払方法が重複どうしで違う）。
-- 変更: 前回（口座が同一の5グループ）と同じ方式。残す1件へ請求書を付け替え、重複側は削除せず無効化して統合先をnotesに記録、付替えは vendor_merge_log に記録（戻せる）。
--   銀行口座: 1取引先につき現在有効(is_current)は高々1件の制約があるため、残す側の口座を基本に、重複側の口座は過去口座(is_current=false)にする。
--     ただし Mostfun（新しい口座＝銀行振込2952）と 野村不動産コマース（新しい口座＝3712）は、直近の請求書が使っている新しい口座を現在有効にし、元の口座は過去口座にする。
--   支払方法: 統合前に「現金」で未払いだった NTT ME の請求書(2026-10分)は、この月だけ現金のまま扱えるよう vendor_payment_overrides に記録して支払方法を保つ。
--   他の請求書はすべて支払済み・確認済みで、支払方法の変更の影響を受けない（確認済み）。
-- 重複判定は請求書ベース（請求番号・金額×期限）のまま。同じ取引先から同月に複数の請求書が届くこと自体は重複と見なさない（定期請求書10社の「月1枚」ルールだけが例外）。
-- 既存データへの影響: 請求書の取引先IDが付け替わる（名前・金額・支払状態は変わらない）。

-- NTT ME株式会社: 残す=f91c733b-5bb0-401c-ab11-66d79bd2cccb
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select 'f91c733b-5bb0-401c-ab11-66d79bd2cccb', '249569bf-9029-4b86-a06f-c137384fcf4d', id from public.invoices where vendor_id='249569bf-9029-4b86-a06f-c137384fcf4d';
update public.invoices set vendor_id='f91c733b-5bb0-401c-ab11-66d79bd2cccb', updated_at=now() where vendor_id='249569bf-9029-4b86-a06f-c137384fcf4d';
update public.vendor_bank_accounts set is_current=false where vendor_id='249569bf-9029-4b86-a06f-c137384fcf4d';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のためf91c733b-5bb0-401c-ab11-66d79bd2cccbに統合（2026-10-13）', updated_at=now() where id='249569bf-9029-4b86-a06f-c137384fcf4d';
-- 有限会社トーホーエージェンシー: 残す=971bd630-fbe4-4750-8f12-535c67cf7f47
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '971bd630-fbe4-4750-8f12-535c67cf7f47', '8bf6600c-221b-4714-b726-dd9bf9e3f5f1', id from public.invoices where vendor_id='8bf6600c-221b-4714-b726-dd9bf9e3f5f1';
update public.invoices set vendor_id='971bd630-fbe4-4750-8f12-535c67cf7f47', updated_at=now() where vendor_id='8bf6600c-221b-4714-b726-dd9bf9e3f5f1';
update public.vendor_bank_accounts set is_current=false where vendor_id='8bf6600c-221b-4714-b726-dd9bf9e3f5f1';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため971bd630-fbe4-4750-8f12-535c67cf7f47に統合（2026-10-13）', updated_at=now() where id='8bf6600c-221b-4714-b726-dd9bf9e3f5f1';
-- 株式会社Mostfun: 残す=6a01b727-a4a4-4db1-a74b-000ae3f2d5e3
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '6a01b727-a4a4-4db1-a74b-000ae3f2d5e3', '5a814938-17cc-484c-9e28-0e7c2277115c', id from public.invoices where vendor_id='5a814938-17cc-484c-9e28-0e7c2277115c';
update public.invoices set vendor_id='6a01b727-a4a4-4db1-a74b-000ae3f2d5e3', updated_at=now() where vendor_id='5a814938-17cc-484c-9e28-0e7c2277115c';
update public.vendor_bank_accounts set is_current=false, valid_to=coalesce(valid_to, current_date) where vendor_id='6a01b727-a4a4-4db1-a74b-000ae3f2d5e3' and is_current;
update public.vendor_bank_accounts set vendor_id='6a01b727-a4a4-4db1-a74b-000ae3f2d5e3' where vendor_id='5a814938-17cc-484c-9e28-0e7c2277115c' and is_current;
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため6a01b727-a4a4-4db1-a74b-000ae3f2d5e3に統合（2026-10-13）', updated_at=now() where id='5a814938-17cc-484c-9e28-0e7c2277115c';
-- 株式会社カカクコム: 残す=33c6df09-4c18-41b6-bff3-2cf102421d72
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '33c6df09-4c18-41b6-bff3-2cf102421d72', 'b2119c56-d674-4bbd-8f33-c549064427b0', id from public.invoices where vendor_id='b2119c56-d674-4bbd-8f33-c549064427b0';
update public.invoices set vendor_id='33c6df09-4c18-41b6-bff3-2cf102421d72', updated_at=now() where vendor_id='b2119c56-d674-4bbd-8f33-c549064427b0';
update public.vendor_bank_accounts set is_current=false where vendor_id='b2119c56-d674-4bbd-8f33-c549064427b0';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため33c6df09-4c18-41b6-bff3-2cf102421d72に統合（2026-10-13）', updated_at=now() where id='b2119c56-d674-4bbd-8f33-c549064427b0';
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '33c6df09-4c18-41b6-bff3-2cf102421d72', '33a22dfd-bcb7-458f-a62e-aadd3d31d5e4', id from public.invoices where vendor_id='33a22dfd-bcb7-458f-a62e-aadd3d31d5e4';
update public.invoices set vendor_id='33c6df09-4c18-41b6-bff3-2cf102421d72', updated_at=now() where vendor_id='33a22dfd-bcb7-458f-a62e-aadd3d31d5e4';
update public.vendor_bank_accounts set is_current=false where vendor_id='33a22dfd-bcb7-458f-a62e-aadd3d31d5e4';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため33c6df09-4c18-41b6-bff3-2cf102421d72に統合（2026-10-13）', updated_at=now() where id='33a22dfd-bcb7-458f-a62e-aadd3d31d5e4';
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '33c6df09-4c18-41b6-bff3-2cf102421d72', '97b758d6-676b-407e-893e-ca4cad016149', id from public.invoices where vendor_id='97b758d6-676b-407e-893e-ca4cad016149';
update public.invoices set vendor_id='33c6df09-4c18-41b6-bff3-2cf102421d72', updated_at=now() where vendor_id='97b758d6-676b-407e-893e-ca4cad016149';
update public.vendor_bank_accounts set is_current=false where vendor_id='97b758d6-676b-407e-893e-ca4cad016149';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため33c6df09-4c18-41b6-bff3-2cf102421d72に統合（2026-10-13）', updated_at=now() where id='97b758d6-676b-407e-893e-ca4cad016149';
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '33c6df09-4c18-41b6-bff3-2cf102421d72', 'f91b2441-9d3a-43b9-96e4-be0d094e634a', id from public.invoices where vendor_id='f91b2441-9d3a-43b9-96e4-be0d094e634a';
update public.invoices set vendor_id='33c6df09-4c18-41b6-bff3-2cf102421d72', updated_at=now() where vendor_id='f91b2441-9d3a-43b9-96e4-be0d094e634a';
update public.vendor_bank_accounts set is_current=false where vendor_id='f91b2441-9d3a-43b9-96e4-be0d094e634a';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため33c6df09-4c18-41b6-bff3-2cf102421d72に統合（2026-10-13）', updated_at=now() where id='f91b2441-9d3a-43b9-96e4-be0d094e634a';
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '33c6df09-4c18-41b6-bff3-2cf102421d72', '520e1031-5ae8-43f7-b1e1-405cb5c9be78', id from public.invoices where vendor_id='520e1031-5ae8-43f7-b1e1-405cb5c9be78';
update public.invoices set vendor_id='33c6df09-4c18-41b6-bff3-2cf102421d72', updated_at=now() where vendor_id='520e1031-5ae8-43f7-b1e1-405cb5c9be78';
update public.vendor_bank_accounts set is_current=false where vendor_id='520e1031-5ae8-43f7-b1e1-405cb5c9be78';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため33c6df09-4c18-41b6-bff3-2cf102421d72に統合（2026-10-13）', updated_at=now() where id='520e1031-5ae8-43f7-b1e1-405cb5c9be78';
-- 野村不動産コマース株式会社: 残す=7611450d-8e96-43ac-9ef7-9586ca010e83
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '7611450d-8e96-43ac-9ef7-9586ca010e83', '24f1a5db-6bb8-470a-ad95-05da97761c71', id from public.invoices where vendor_id='24f1a5db-6bb8-470a-ad95-05da97761c71';
update public.invoices set vendor_id='7611450d-8e96-43ac-9ef7-9586ca010e83', updated_at=now() where vendor_id='24f1a5db-6bb8-470a-ad95-05da97761c71';
update public.vendor_bank_accounts set is_current=false where vendor_id='24f1a5db-6bb8-470a-ad95-05da97761c71';
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため7611450d-8e96-43ac-9ef7-9586ca010e83に統合（2026-10-13）', updated_at=now() where id='24f1a5db-6bb8-470a-ad95-05da97761c71';
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id) select '7611450d-8e96-43ac-9ef7-9586ca010e83', '06666825-ed85-478d-a153-9a662dd2be79', id from public.invoices where vendor_id='06666825-ed85-478d-a153-9a662dd2be79';
update public.invoices set vendor_id='7611450d-8e96-43ac-9ef7-9586ca010e83', updated_at=now() where vendor_id='06666825-ed85-478d-a153-9a662dd2be79';
update public.vendor_bank_accounts set is_current=false, valid_to=coalesce(valid_to, current_date) where vendor_id='7611450d-8e96-43ac-9ef7-9586ca010e83' and is_current;
update public.vendor_bank_accounts set vendor_id='7611450d-8e96-43ac-9ef7-9586ca010e83' where vendor_id='06666825-ed85-478d-a153-9a662dd2be79' and is_current;
update public.vendors set is_active=false, notes=coalesce(notes||E'\n','')||'同名重複のため7611450d-8e96-43ac-9ef7-9586ca010e83に統合（2026-10-13）', updated_at=now() where id='06666825-ed85-478d-a153-9a662dd2be79';
insert into public.vendor_payment_overrides(vendor_id, year_month, payment_method, note) values ('f91c733b-5bb0-401c-ab11-66d79bd2cccb', '2026-10', 'cash', '統合前の請求書(00220261005015131)は現金払いのため、この月だけ現金を保持') on conflict (vendor_id, year_month) do nothing;
