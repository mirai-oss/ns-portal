-- 【事前報告様式（DB変更）】担当C・2026-10-14「人がスキャン/アップロードした請求書も自動で判別・仕訳下書き→承認待ちへ」
-- 理由: アップロード入口の請求書を、メール自動取込と同じ流れ（読み取り→取引先・法人の判定→明細→仕訳下書き→検算→承認待ち）に乗せる。
--       自動処理に乗せたものを「人が手入力した請求書」と区別するため、invoices.intake_source に 'upload_auto' を追加する。
-- 変更: invoices_intake_source_check の許可値に 'upload_auto' を追加するだけ（既存の値・既存データは変更なし）。
-- rollback: 'upload_auto' の行が無いことを確認してから、元の制約（mail,paper,pdf,infomart,api,manual,email_auto）へ戻す。
alter table public.invoices drop constraint if exists invoices_intake_source_check;
alter table public.invoices add constraint invoices_intake_source_check
  check (intake_source = any (array['mail','paper','pdf','infomart','api','manual','email_auto','upload_auto']));
