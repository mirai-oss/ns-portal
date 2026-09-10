-- 2026-09-10: 請求書一覧で「給料なのか請求書なのか区別がつかない」への対応
-- （担当C・invoices.html）
-- ユーザー要望「請求書一覧のところで給料なのか請求書なのか区別がつかないので、
-- 絞り込みできるようにしてほしい」への回答。AskUserQuestionで確認したところ、
-- 「給与関連の請求書がある」＝給与仕訳タブ（sf_payroll_sync等）とは別に、
-- 🧾請求書一覧（invoices）の中に人材紹介・派遣費用など給与相当の性質を持つ
-- 請求書が混ざっており、通常の請求書と見分けがつかないとのこと。

alter table invoices
  add column if not exists is_payroll_related boolean not null default false;

comment on column invoices.is_payroll_related is
  '給与関連の請求書（人材紹介・派遣費用等、性質上は給与に近いが給与仕訳タブではなく
   通常の請求書処理で扱うもの）かどうかのフラグ。請求書詳細の「請求情報」カードで
   手動設定し、🧾請求書一覧で絞り込めるようにする（2026-09-10・ユーザー要望対応）。';
