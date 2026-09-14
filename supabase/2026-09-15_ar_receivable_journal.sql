-- 2026-09-15: 売上入金（ar_receivables）から実際のMF仕訳を作成する機能に対応する
-- スキーマ追加。ロケットナウ（デリバリー精算）の実データがar_receivablesへ投入完了
-- （担当A・2026-09-14。鳥一代本店8月分：売上¥132,511・手数料¥45,538・精算予定額¥82,413）
-- したことを受け、担当Cが「🧾仕訳を作成」機能を実装するために必要な追加。
--
-- 【なぜ必要か】
-- 既存のmf-journal Edge Function「create」アクションは、必ずinvoices.idを起点にする設計
-- （invoice_id必須・成功時にinvoices.mf_journal_id等を更新する）。ar_receivablesの行を
-- 直接渡して仕訳登録することはできない。一方でar_receivablesはinvoices（支払う側＝
-- 請求書）とは別の名前空間（売上入金＝入ってくる側）のため、単純にinvoicesへ登録すると
-- 🧾請求書一覧（支払うべき請求書の一覧）に「売上入金」の行が紛れ込んで混乱する。
-- 既存のis_payroll_related（給与仕訳関連のinvoices行を🧾請求書一覧の集計・表示から
-- 除外している仕組み）と全く同じパターンで、is_receivable_relatedを新設し同様に除外する。
--
-- 【現在の構造】
-- invoices: 請求書（支払う側）の正本。is_payroll_relatedがtrueの行は🧾請求書一覧
-- （unifiedRender）の集計・表示から除外される既存の仕組みがある。
-- ar_receivables: 売上入金（入ってくる側）の正本（Step4で新設）。mf仕訳との連携列は
-- まだ無い。
--
-- 【今回の変更】
-- 1. invoices.is_receivable_related（boolean・既定false）を新設。ar_receivablesからの
--    仕訳作成のためだけに内部的に作るinvoices行にtrueを立てる。
-- 2. ar_receivables.linked_invoice_id（uuid・invoices.idへの参照）・mf_journal_id
--    （uuid）・mf_journal_number（text）・mf_journal_created_at（timestamptz）を新設。
--    仕訳登録が完了したかどうかを売上入金タブの一覧・行の操作ボタンから判定できるようにする。
--
-- 【既存データへの影響】無し（新規列の追加のみ・default値により既存行は全てfalse/null）
-- 【migration】このファイル自体（ALTER TABLE ADD COLUMN IF NOT EXISTSのみ・冪等）
-- 【rollback】
--   alter table invoices drop column if exists is_receivable_related;
--   alter table ar_receivables drop column if exists linked_invoice_id, drop column if exists mf_journal_id, drop column if exists mf_journal_number, drop column if exists mf_journal_created_at;
-- 【既存機能への影響】無し。unifiedRender（🧾請求書一覧）のフィルタにis_receivable_related
-- の除外を1箇所追加するが、これは新規に作るinvoices行だけに影響し、既存の請求書データは
-- is_receivable_related=falseのままのため無関係。

alter table invoices add column if not exists is_receivable_related boolean not null default false;
comment on column invoices.is_receivable_related is
  '売上入金（ar_receivables）からMF仕訳を作成するために内部的に作られたinvoices行の場合true。
   🧾請求書一覧（unifiedRender）の集計・表示から除外する（is_payroll_relatedと同じ扱い）。';

alter table ar_receivables add column if not exists linked_invoice_id uuid references invoices(id);
alter table ar_receivables add column if not exists mf_journal_id uuid;
alter table ar_receivables add column if not exists mf_journal_number text;
alter table ar_receivables add column if not exists mf_journal_created_at timestamptz;
comment on column ar_receivables.linked_invoice_id is
  'この売上入金の仕訳作成のために内部的に作られたinvoices行のid（mf-journal Edge Function
   がinvoice_idを必須にしているための橋渡し。invoices.is_receivable_related=trueの行を指す）。';
