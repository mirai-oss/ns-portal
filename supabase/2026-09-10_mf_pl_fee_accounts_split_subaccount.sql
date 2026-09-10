-- 2026-09-10: mf_pl_fee_accounts（PL連携対象科目）に補助科目列を分離
-- （担当C・invoices.html。ユーザー報告「請求書のところ、PLマッピングもマネーフォワード
-- 会計と同じようになってない」への対応）
--
-- 従来はaccount_name列に「勘定科目/補助科目」を1本の文字列としてまとめて登録していた
-- （例: "広告宣伝費/TAGZ"）。2026-09-10の「勘定科目と補助科目を分けて、マネーフォワードの
-- 勘定科目と補助科目と同じように連動してほしい」対応で、仕訳入力・給与仕訳・PLへ反映の
-- 手動指定欄はすべて.pet-acc-group形式（勘定科目→補助科目の2段・補助科目はMF APIから
-- 連動）に揃えたが、この「PL連携対象科目」一覧（＝どの科目がPL科目として有効かの定義）
-- だけが元の1本文字列のままで、以下2点が壊れていた:
--   ①手動指定欄の勘定科目候補（plfee-acc-dl）に「広告宣伝費/TAGZ」等の結合文字列が
--     そのまま出てしまう（勘定科目名として見えるのに実際は補助科目まで含んだ値）
--   ②confirm時の「PL科目として登録済みか」チェックがaccount_name完全一致だけを見ており、
--     分離済みのsub_account_nameを無視していたため、勘定科目を分けて指定すると
--     （例: 勘定科目="広告宣伝費"・補助科目="TAGZ"）一致せず「PL科目として登録されて
--     いません」で弾かれてしまう（=分離後のUIでは実質PL反映できなくなっていた）
--   ③仕訳から自動検出するplfeeLoadJournalGroups()の対象科目フィルタも同じ理由で
--     account_name完全一致だけを見ており、実際のMF仕訳（勘定科目・補助科目が分かれた
--     状態）とはほぼ一致しないため、登録済みのはずの科目が自動検出候補に出てこない

alter table mf_pl_fee_accounts add column if not exists sub_account_name text;

-- account_name単体のユニーク制約だと、分割後に同じ勘定科目で補助科目違いの複数行
-- （例: 広告宣伝費/TAGZ・広告宣伝費/食べログ）が共存できず分割時点でエラーになる。
-- 先に制約を外し、分割後に(account_name, sub_account_name)の組で一意にし直す
alter table mf_pl_fee_accounts drop constraint if exists mf_pl_fee_accounts_account_name_key;

-- 既存の「勘定科目/補助科目」形式のaccount_nameを分割する（"/"が無い行＝支払手数料等は
-- そのまま・sub_account_nameはnull）
update mf_pl_fee_accounts
  set sub_account_name = nullif(trim(substring(account_name from position('/' in account_name) + 1)), ''),
      account_name = trim(substring(account_name from 1 for position('/' in account_name) - 1))
  where account_name like '%/%';

alter table mf_pl_fee_accounts add constraint mf_pl_fee_accounts_account_sub_key unique (account_name, sub_account_name);

comment on column mf_pl_fee_accounts.sub_account_name is
  '補助科目（マネーフォワードの補助科目名。無ければnull）。2026-09-10にaccount_nameから
   分離（旧形式は"勘定科目/補助科目"の結合文字列だった）。';
