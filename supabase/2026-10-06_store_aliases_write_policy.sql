-- 担当C: 給与仕訳の全自動化 §2「タイムカード事業所名→店舗」をその場で登録できるようにする
-- 設計の正: docs/設計書_給与仕訳の全自動化_2026-10-06.md §2
--
-- 【事前報告様式（DB変更）】
-- 理由: 給与明細PDF／スマレジの事業所名が店舗マスタと一致しないとき、画面の「この店舗として登録」ボタンで
--       store_aliases へ別名を登録したい（次回から同じ事業所名を同じ店舗と認識させる）。
-- 現構造: store_aliases(alias pk, store_id, source, created_at, kind) は RLS が「select(ログイン済み全員)」だけで、
--         書き込みポリシーが無い＝画面(ログインユーザー権限)からは登録できない。列は既に source(メモ) と kind があり追加不要。
-- 変更（追加のみ・既存の行/列/ポリシー/他システムの読み取りは不変）:
--   store_aliases に insert/update/delete のポリシーを1本追加。条件は請求書・会計系の他テーブル（invoice_stores 等）と同じ
--   invoice_can_access()（請求書・会計ワークスペースを使える権限の人だけ）。
--   別名は alias が主キー（1つの名前は1店舗にだけ対応）。画面側で「既に別の店舗に登録済み」はエラーとして表示する。
--   タイムカード由来の別名は source='smaregi_timecard'・kind='name' で登録する（PL店舗名は既存列 stores.seisan_store_name を使い、列追加なし）。
-- 既存データへの影響: なし（ポリシー追加のみ）。
-- migration: 本ファイル(何度流しても壊れない)。 rollback: drop policy store_aliases_write_inv on store_aliases;

alter table public.store_aliases enable row level security;

drop policy if exists store_aliases_write_inv on public.store_aliases;
create policy store_aliases_write_inv on public.store_aliases
  for all
  using (invoice_can_access())
  with check (invoice_can_access());
