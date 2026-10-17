-- =====================================================================
-- 取引先マスタ: 「株式会社プレコ」を「株式会社プレコフーズ」へ統合（担当F・TK-221/TK-227）
-- ユーザー確認（2026-10-17）: 同じ会社。（根拠: 「プレコ」の振込先口座の名義カナが「株式会社プレコフーズ」）
--
-- 【事前報告様式（DB変更）】
-- 理由: 同じ会社が2つの取引先に分かれている。プレコフーズ側には登録番号・別名・行ルール・支払設定・インボイス注意があり、
--       プレコ側には請求書1件と振込先口座がある。
-- 現構造（2026-10-17 本番を読み取り専用で確認）: 残す「株式会社プレコフーズ」=別名2・行ルール1・支払設定(銀行振込)1・インボイス注意1・口座0・請求書0。
--   統合する「株式会社プレコ」=請求書1件（000126389・99,000円・支払済み）・口座1件（みずほ銀行 シラカバ支店 普通 1496909・現在の口座）。
-- 変更（前回と同じ方式・削除なし）:
--   請求書1件を残す側へ付替え（vendor_merge_log に記録）／口座1件も残す側へ付替え（残す側に口座が無いので、そのまま現在の口座になる・支払方法=銀行振込で支払設定と一致）／
--   「株式会社プレコ」は無効化（is_active=false・notesに統合先）／「株式会社プレコ」の名前を残す側の別名（vendor_aliases・source='merge_2026-10-17'）に登録。
-- 既存データへの影響: 請求書の取引先IDと口座の持ち主が付け替わるだけ（名前・金額・支払状態・MF登録・口座の内容は変わらない）。
-- 冪等（無効化済みなら何もしない）。 取り消し: 末尾のコメント参照。
-- =====================================================================
create table if not exists public.vendor_merge_log (
  id bigserial primary key, merged_at timestamptz not null default now(),
  keeper_vendor_id uuid not null, dup_vendor_id uuid not null, invoice_id uuid not null
);

create temp table _vm (keeper uuid, keeper_name text, dup uuid, dup_name text) on commit drop;
insert into _vm values
  ('52692ee5-8a57-47ad-919b-5e547af3b48c'::uuid, '株式会社プレコフーズ', '5fb9f0d4-2866-4497-88db-22ec45ad36fd'::uuid, '株式会社プレコ');

-- 名前の取り違え防止（本番のIDと名前が想定どおりのものだけ処理する）
delete from _vm m using public.vendors k, public.vendors d
 where k.id = m.keeper and d.id = m.dup and (k.name <> m.keeper_name or d.name <> m.dup_name);

insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id)
select m.keeper, m.dup, i.id from _vm m join public.vendors d on d.id = m.dup and d.is_active
  join public.invoices i on i.vendor_id = m.dup;
update public.invoices i set vendor_id = m.keeper, updated_at = now()
  from _vm m join public.vendors d on d.id = m.dup and d.is_active where i.vendor_id = m.dup;
-- 口座: 残す側に現在の口座が無いときだけ、重複側の口座をそのまま残す側へ（あれば重複側は過去口座に）
update public.vendor_bank_accounts b set vendor_id = m.keeper, updated_at = now()
  from _vm m join public.vendors d on d.id = m.dup and d.is_active
 where b.vendor_id = m.dup and b.is_current
   and not exists (select 1 from public.vendor_bank_accounts x where x.vendor_id = m.keeper and x.is_current);
update public.vendor_bank_accounts b set is_current = false
  from _vm m join public.vendors d on d.id = m.dup and d.is_active where b.vendor_id = m.dup and b.is_current;
insert into public.vendor_aliases (vendor_id, alias, source)
select m.keeper, m.dup_name, 'merge_2026-10-17' from _vm m join public.vendors d on d.id = m.dup and d.is_active
on conflict (alias, source) do nothing;
update public.vendors d set is_active = false, updated_at = now(),
       notes = coalesce(d.notes || E'\n', '') || '表記違いの重複のため' || m.keeper::text || '（' || m.keeper_name || '）に統合（2026-10-17）'
  from _vm m where d.id = m.dup and d.is_active;

-- rollback:
--   update public.invoices set vendor_id = '5fb9f0d4-2866-4497-88db-22ec45ad36fd', updated_at = now()
--    where id in (select invoice_id from public.vendor_merge_log where dup_vendor_id = '5fb9f0d4-2866-4497-88db-22ec45ad36fd');
--   update public.vendor_bank_accounts set vendor_id = '5fb9f0d4-2866-4497-88db-22ec45ad36fd' where vendor_id = '52692ee5-8a57-47ad-919b-5e547af3b48c' and account_number = '1496909';
--   update public.vendors set is_active = true where id = '5fb9f0d4-2866-4497-88db-22ec45ad36fd';
--   delete from public.vendor_aliases where source = 'merge_2026-10-17' and alias = '株式会社プレコ';
--   delete from public.vendor_merge_log where dup_vendor_id = '5fb9f0d4-2866-4497-88db-22ec45ad36fd';
