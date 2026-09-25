-- 2026-09-26: 売上入金（ar_receivables）のPayPay売上・手数料を業務委託精算店舗（stores.
-- seisan_target/seisan_pl_categories_target）向けに業務委託精算書へも自動反映するための追加。
-- 「🧾仕訳を作成」→MoneyForwardへの仕訳登録と同時に、対象店舗であれば自動で業務委託精算書
-- （seisan-dashboard）へ「PayPay売上」「PayPay手数料」の2行を送る（既存のinvoice_pl_reflections
-- のseisan経路と同じsd_apiAddExternalLine呼び出し。方式はpl-fee-reflect/index.tsのseisan_confirm
-- を参照）。MoneyForwardへの直接仕訳登録は変更しない（両方登録する方針・ユーザー確認済み）。
--
-- 【影響】新規列の追加のみ。既存データ・既存機能への影響なし。
-- 【rollback】
--   alter table ar_receivables drop column if exists seisan_synced_at, drop column if exists seisan_sync_error;

alter table ar_receivables add column if not exists seisan_synced_at timestamptz;
alter table ar_receivables add column if not exists seisan_sync_error text;
comment on column ar_receivables.seisan_synced_at is
  '業務委託精算店舗向けに「PayPay売上」「PayPay手数料」を業務委託精算書へ登録した日時
   （対象外の店舗＝seisan_target/seisan_pl_categories_targetどちらも無い、または黒霧屋のような
   使い分け店舗で直接支払い扱いの場合はnullのまま。詳細はpl-fee-reflect/index.tsの
   seisan_confirm_receivableアクション参照）';
comment on column ar_receivables.seisan_sync_error is
  '業務委託精算書への登録に失敗した場合のエラー内容（MoneyForwardへの仕訳登録自体は
   この失敗と無関係に成功する。次回「状態を更新」等での再試行は現状未実装のため、
   失敗時は担当者へ連絡し手動で確認する）';
