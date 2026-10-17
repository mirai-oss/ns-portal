-- =====================================================================
-- 取引先マスタ: 「株式会社」「㈱」の表記違いで重複している5グループ（7行→5行）の統合（担当F・TK-221の続き）
-- 前回（2026-10-13・担当C）は「同じ名前」の重複29行を統合済み。今回は名前の書き方（株式会社／㈱／無し）だけが違う同一会社を統合する。
--
-- 【事前報告様式（DB変更）】
-- 理由: 同じ会社が表記違いで別の取引先として登録されている（請求書の取込・アップロードのたびに新規登録された）。取引先の確定・重複判定・支払方法の判断が分かれる。
-- 現構造（2026-10-17 本番を読み取り専用で確認）: 有効な取引先95件のうち、「株式会社/有限会社/㈱…」を除いた名前が同じになるのは5グループ（下記）。
--   参照は請求書（各1〜3件）と振込先口座（各1件）だけ。別名・行ルール・仕訳辞書・精算書の設定などは無し（確認済み）。
-- 変更（前回と同じ方式・削除はしない）:
--   残す1件=正式な会社名（「株式会社〜」の形。ユーザー決定「取引先名は登記上の正式名称」）。重複側の請求書を残す側へ付け替え、
--   重複側は無効化（is_active=false）して notes に統合先を記録、付替えは vendor_merge_log に記録（戻せる）。
--   重複側の振込先口座は過去口座にする（is_current=false。残す側の口座が現在の口座）。
--   重複側の名前は残す側の別名（vendor_aliases・source='merge_2026-10-17'）に登録＝請求書で今後「㈱インフォマート」と書かれても同じ取引先と判定される。
-- 対象（残す←統合）:
--   株式会社スマレジ ← スマレジ／藤ビルメンテナンス株式会社 ← 藤ビルメンテナンス／株式会社N-Style ← 株式会社N-style・N-style／
--   株式会社インフォマート ← ㈱インフォマート／株式会社西田コーポレーション ← ㈱西田コーポレーション
-- 含めない: 「株式会社プレコ」と「株式会社プレコフーズ」（別会社かもしれないためユーザー確認待ち＝TK-227）。
-- 既存データへの影響: 請求書の取引先IDだけが付け替わる（名前・金額・支払状態・MF登録は変わらない）。
-- 注意（確認済み）: 統合しても請求書の重複判定（請求番号・金額×期限）は変わらない。重複側と残す側で請求番号・金額・期限が同じ請求書は無い。
--   支払方法: 残す側の口座の支払方法になる（インフォマート=口座振替・N-Style=銀行振込・他は変わらず）。重複側の過去の請求書は支払済みで影響なし。
-- 冪等（無効化済みの重複側は再実行しても何もしない）。 取り消し: 付け替えた請求書を vendor_merge_log から戻し、重複側を is_active=true に戻す。
-- =====================================================================
create table if not exists public.vendor_merge_log (
  id bigserial primary key, merged_at timestamptz not null default now(),
  keeper_vendor_id uuid not null, dup_vendor_id uuid not null, invoice_id uuid not null
);

create temp table _vm (keeper uuid, keeper_name text, dup uuid, dup_name text) on commit drop;
insert into _vm values
  ('4b3293fc-d4f8-4f20-831b-a928983012a4'::uuid, '藤ビルメンテナンス株式会社', '3e5ce896-2f82-4b6a-bd68-b4425d8854a8'::uuid, '藤ビルメンテナンス'),
  ('104a7534-ab79-4133-ac11-7e10abe517dd'::uuid, '株式会社スマレジ', 'f9481c9d-209d-4aed-a19a-3750c3d53113'::uuid, 'スマレジ'),
  ('6ffed9f5-267c-4d78-9002-898c81a3b83c'::uuid, '株式会社N-Style', 'bcdd8487-a83a-4b2b-9e15-460c5c83cfd0'::uuid, '株式会社N-style'),
  ('6ffed9f5-267c-4d78-9002-898c81a3b83c'::uuid, '株式会社N-Style', 'f3eeb76b-8ab3-4d7a-b1d9-8cc69bd95947'::uuid, 'N-style'),
  ('c1005327-8b5c-4f88-bbd6-61867136fba5'::uuid, '株式会社インフォマート', '1631d199-ccf1-4ceb-a908-ef520e9740e8'::uuid, '㈱インフォマート'),
  ('9ebc62ad-d6c2-4059-b57a-75605113859d'::uuid, '株式会社西田コーポレーション', '3ade6eaf-22c8-4894-af77-a5d3f43cd030'::uuid, '㈱西田コーポレーション');

-- 名前の取り違え防止（本番のIDと名前が想定どおりのものだけ処理する）
delete from _vm m using public.vendors k, public.vendors d
 where k.id = m.keeper and d.id = m.dup and (k.name <> m.keeper_name or d.name <> m.dup_name);

-- 1) 付替えを記録（まだ有効な重複側だけ）
insert into public.vendor_merge_log(keeper_vendor_id, dup_vendor_id, invoice_id)
select m.keeper, m.dup, i.id from _vm m join public.vendors d on d.id = m.dup and d.is_active
  join public.invoices i on i.vendor_id = m.dup;
-- 2) 請求書を残す側へ
update public.invoices i set vendor_id = m.keeper, updated_at = now()
  from _vm m join public.vendors d on d.id = m.dup and d.is_active where i.vendor_id = m.dup;
-- 3) 重複側の口座は過去口座に
update public.vendor_bank_accounts b set is_current = false
  from _vm m join public.vendors d on d.id = m.dup and d.is_active where b.vendor_id = m.dup and b.is_current;
-- 4) 重複側の名前を残す側の別名に（請求書での表記ゆれ→同じ取引先）
insert into public.vendor_aliases (vendor_id, alias, source)
select m.keeper, m.dup_name, 'merge_2026-10-17' from _vm m join public.vendors d on d.id = m.dup and d.is_active
on conflict (alias, source) do nothing;
-- 5) 重複側を無効化
update public.vendors d set is_active = false, updated_at = now(),
       notes = coalesce(d.notes || E'
', '') || '表記違いの重複のため' || m.keeper::text || '（' || m.keeper_name || '）に統合（2026-10-17）'
  from _vm m where d.id = m.dup and d.is_active;

-- rollback（統合前は重複側の口座は全て「現在の口座」だった。付け替えた請求書・口座・有効状態・別名を戻す）:
--   update public.invoices i set vendor_id = l.dup_vendor_id, updated_at = now() from public.vendor_merge_log l
--    where l.invoice_id = i.id and l.merged_at >= timestamp '2026-10-17';
--   update public.vendor_bank_accounts set is_current = true where vendor_id in (select id from public.vendors where notes like '%に統合（2026-10-17）%');
--   update public.vendors set is_active = true where notes like '%に統合（2026-10-17）%';
--   delete from public.vendor_aliases where source = 'merge_2026-10-17';
--   delete from public.vendor_merge_log where merged_at >= timestamp '2026-10-17';
