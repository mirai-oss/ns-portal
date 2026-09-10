-- 2026-09-10: invoice_pl_reflections（PL反映の実績記録）に残っていた、勘定科目・補助科目を
-- 分離する前（2026-09-10より前）の「勘定科目/補助科目」結合形式のaccount_nameを正規化する
-- （担当C・ユーザー報告「黒霧屋の販売促進費の合同会社ReBORNも消えてる」対応。合わせて調査したところ
-- 同種の結合形式データが他に8件見つかった）。
--
-- 経緯: PLへ反映パネルの手動指定欄は2026-09-10に「勘定科目/補助科目」を分けた形式へ変更したが、
-- それ以前（2026-09-02〜09-10午前）にPL反映された行は、account_nameに結合文字列がそのまま
-- 入っており（一部はsub_account_nameも正しく分かれていたが、account_name自体には結合文字列が
-- 残ったままだった）、tori-dashboard側（writeAccountCostToPl_）へ渡すaccount名も結合文字列の
-- ままになっていた。その結果、経営ダッシュボードのPL画面では「販売促進費」の下に補助科目として
-- 出てくるはずが、「販売促進費/合）ReBORN」という全く別の勘定科目として表示され、期待した場所
-- （販売促進費の内訳）には出てこない状態になっていた。
--
-- このSQLはns-portal側のデータだけを正規化する（DB_PL・PL管理システム側の既存の結合形式の行は
-- このSQLでは直らない。正規化後、担当Cが該当分をwritePlFeeへ再送して正しい行を新規作成する。
-- 古い結合形式の行はDB_PL側に削除APIが無いため孤立して残る＝担当Aへ手動削除を依頼する）。

update invoice_pl_reflections
  set sub_account_name = coalesce(sub_account_name, nullif(trim(substring(account_name from position('/' in account_name) + 1)), '')),
      account_name = trim(substring(account_name from 1 for position('/' in account_name) - 1))
  where account_name like '%/%';
