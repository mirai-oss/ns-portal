-- 売上入金の手数料を「課税」「非課税」に分けて持てるようにする（2026-09-30・ユーザー要望）
-- 背景: SMBC GMO PAYMENT（カード売上）の振込明細書は、決済手数料が「決済手数料課税対象額」
-- 「決済手数料非課税対象額」の2つに分かれており、仕訳辞書（mf_journal_templates）側も
-- 「カード手数料（課税仕入10%）」「カード手数料（対象外）」の2明細行を想定していた。
-- しかしar_receivablesは手数料を fee_amount 1本でしか持てず、invoices.html側の自動流し込み
-- （arjApplyTemplateAsDefault_）も[売上,手数料]の2枠しか対応していなかったため、手数料明細が
-- 常に1本しか仕訳候補に出ていなかった（ユーザー報告）。
--
-- 【影響】新規カラム追加のみ（どちらもnullable）。既存の読み書き（fee_amount）は変更しない。
-- fee_amount_taxable/fee_amount_exemptが両方nullの行（既存の全データ）は、invoices.html側で
-- 従来どおりfee_amountの単一明細のまま扱われる（後方互換）。
-- 【rollback】 alter table public.ar_receivables drop column if exists fee_amount_taxable, drop column if exists fee_amount_exempt;

alter table public.ar_receivables
  add column if not exists fee_amount_taxable numeric,
  add column if not exists fee_amount_exempt numeric;

comment on column public.ar_receivables.fee_amount_taxable is '手数料のうち課税対象額（任意・無ければfee_amountを単一明細として扱う）';
comment on column public.ar_receivables.fee_amount_exempt is '手数料のうち非課税対象額（任意）';
