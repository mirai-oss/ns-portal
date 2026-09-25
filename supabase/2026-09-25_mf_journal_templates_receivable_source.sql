-- 仕訳辞書（mf_journal_templates）を「売上入金（ar_receivables）」の自動適用にも使えるようにする。
-- 【背景】既存のjournal_rules_extension（2026-09-03）で追加した source_filter 等の判定条件列は、
-- すべて「請求書（invoices）の取込経路」用の概念（mail/paper/pdf等）であり、売上入金
-- （ar_receivables.source_name、例:「PayPay加盟店」「ロケットナウ」）を表すものではない。
-- ns-portal/invoices.htmlのarjSetDefaultBranches()（PayPay加盟店の売上入金→MF仕訳作成画面）が
-- 「テンプレートのlabelとsource_nameを完全一致させる」という暫定運用をしていたが、labelは
-- ユーザーが自由に付けたい表示名（例:「PayPay売上」）であるべきなので、判定専用の列を分離する。
--
-- 【ロールバック】
-- alter table mf_journal_templates drop column if exists receivable_source_name;
alter table mf_journal_templates
  add column if not exists receivable_source_name text;

comment on column mf_journal_templates.receivable_source_name is
  '売上入金（ar_receivables.source_name）への自動適用キー。この値がar_receivables.source_nameと
   完全一致するとき、この仕訳辞書の勘定科目・補助科目を「MF仕訳を作成」画面の初期値として使う
   （invoices.html: arjSetDefaultBranches）。labelはユーザーが自由に付けられる表示名のままで、
   この列だけを判定に使う。nullなら売上入金への自動適用はしない（従来どおり請求書側の
   判定条件・プリセット選択専用のテンプレートとして扱う）。';
