-- 担当C: アールエスエスの貸方を MFの実際の登録に合わせる（seed Q4の訂正）
-- 理由: seedは「RSSは未払金」だったが、MFの実績は「買掛金／RSS」。登録前チェックで科目・補助科目が見つからず停止した。
-- 変更: vendor_line_rules（株式会社アールエスエス・有効な1行）の貸方を 買掛金／補助=RSS（固定）にする。借方・部門・税は変更なし。
-- rollback: credit_account='未払金', credit_sub_mode='vendor', credit_sub_name=null に戻す。
update public.vendor_line_rules
   set credit_account='買掛金', credit_sub_mode='fixed', credit_sub_name='RSS',
       note = coalesce(note,'') || '／2026-10-14 貸方を実績どおり買掛金／RSSに訂正'
 where vendor_key='株式会社アールエスエス' and is_active;
