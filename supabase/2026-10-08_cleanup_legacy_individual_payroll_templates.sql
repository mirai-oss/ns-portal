-- 担当C: 人ごとの旧「社員給料（個人名）」仕訳辞書を削除できるようにするための参照の解除（1回限り）
-- 事前報告様式（DB変更・本番データの修正）:
-- 理由: ユーザーが「社員給料」（区分=社員）の型を作り、旧い人ごとの仕訳辞書「社員給料（個人名）」10件を削除したい。しかし、
--       payroll_journal_assignments（人ごとの割当）と payroll_journal_records（登録記録）が template_id で参照しており
--       （削除不可の外部キー）、このままでは辞書を削除できない。
-- 対象（実データで確認・2026-10-08）: ラベルが「社員給料」で始まり、区分(payroll_kind)が未設定の仕訳辞書（坂本・アハメドパルベズ・オリサリタ・
--       タマンレスマカラ・地引・杉浦・西内・鈴木・長谷川・青山の10件）。区分=社員の「社員給料」本体と、アルバイトの辞書には触れない。
-- 変更: ① 対象の辞書を参照する payroll_journal_assignments.template_id を null に ② 同じく payroll_journal_records.template_id を null に
--       （記録の「どの辞書で作ったか」の参照だけが消える。伝票番号・金額・MF登録内容には影響しない）
-- 影響: 画面の動作は変わらない（社員は区分「社員」の型で仕訳される）。辞書自体の削除は、この後ユーザーが設定タブで行う。
-- rollback: 参照の復元は不可（記録の参照のみ。必要なら記録時の辞書名は伝票の摘要・MF側の仕訳で確認できる）。
-- migration: 本ファイル（何度流しても壊れない）。

with legacy as (
  select id from public.mf_journal_templates
   where label like '社員給料%' and payroll_kind is null
)
update public.payroll_journal_assignments set template_id = null where template_id in (select id from legacy);

with legacy as (
  select id from public.mf_journal_templates
   where label like '社員給料%' and payroll_kind is null
)
update public.payroll_journal_records set template_id = null where template_id in (select id from legacy);
