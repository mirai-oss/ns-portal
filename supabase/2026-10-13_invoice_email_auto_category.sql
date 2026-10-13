-- 担当C: 請求書メール自動処理 Phase1「メール自動分類」（実装指示書_請求書自動処理_担当CFE Phase1／設計書§2）
--
-- 【事前報告様式（DB変更）】
-- 理由: 取込直後のメールを「請求書(添付あり)／請求通知／ダウンロード型／売上入金／無関係／要確認」に自動分類し、
--       請求書以外のメールにPDF解析をかけない（Phase2以降の前提）。
-- 現構造: invoice_emails は mail_kind（invoice/sales/contract・人の手動分類・NULL=未分類）だけ。分類の出どころ・確信度は持たない。
-- 変更（追加のみ。既存列の改名・意味変更なし。mail_kind/mail_status 等はそのまま並存）:
--   invoice_emails に auto_category / auto_category_by(rule|ai) / auto_confidence / auto_category_reason / auto_classified_at を追加
--   invoice_mail_rules（新規）: 既知送信元・件名・添付有無のルール。AIより先に評価する（①②）
--   automation_rule_settings に 分類AIモデル2種（軽量=Haiku・上位=Sonnet）と確信度しきい値を追加（モデル名はここで切替）
-- 既存データへの影響: なし（既存メールは auto_category=NULL のまま。mail_kind も書き換えない）。
-- ルール: 自動分類は mail_kind が NULL（未分類）のときだけ mail_kind へ写す。人の手動分類（invoice_set_kind）は常に優先・履歴は invoice_audit_logs。
-- migration: 本ファイル（何度流しても壊れない）。 rollback: drop table invoice_mail_rules; alter table invoice_emails drop column auto_category, drop column auto_category_by, drop column auto_confidence, drop column auto_category_reason, drop column auto_classified_at;

alter table public.invoice_emails
  add column if not exists auto_category text check (auto_category in ('invoice_attachment','invoice_notice','invoice_download','sales_deposit','irrelevant','needs_review')),
  add column if not exists auto_category_by text check (auto_category_by in ('rule','ai')),
  add column if not exists auto_confidence numeric(4,3),
  add column if not exists auto_category_reason text,
  add column if not exists auto_classified_at timestamptz;
create index if not exists invoice_emails_auto_category_idx on public.invoice_emails (auto_category);

create table if not exists public.invoice_mail_rules (
  id uuid primary key default gen_random_uuid(),
  rule_type text not null check (rule_type in ('from_domain','from_contains','subject_contains')),
  pattern text not null,
  needs_attachment boolean,                 -- true=添付あり／false=添付なし／NULL=問わない
  category text not null check (category in ('invoice_attachment','invoice_notice','invoice_download','sales_deposit','irrelevant')),
  priority int not null default 100,        -- 小さいほど先に評価
  is_active boolean not null default true,
  note text,
  created_at timestamptz not null default now()
);
alter table public.invoice_mail_rules enable row level security;
drop policy if exists invoice_mail_rules_all_inv on public.invoice_mail_rules;
create policy invoice_mail_rules_all_inv on public.invoice_mail_rules for all using (invoice_can_access()) with check (invoice_can_access());

-- 初期ルール（実データ1386通の送信元・件名を見て、迷わないものだけ。迷うものはAIに任せる）
insert into public.invoice_mail_rules (rule_type, pattern, needs_attachment, category, priority, note)
select * from (values
  ('from_domain','infomart.co.jp', null::boolean, 'invoice_download', 5, 'インフォマート（請求書はサイトからダウンロード）'),
  ('from_domain','billing-robo.jp', null, 'invoice_download', 5, '請求管理ロボ（マイページ配信）'),
  ('from_domain','rbrose.eco-serv.jp', null, 'invoice_download', 6, 'Web帳票サービス（楽楽明細）'),
  ('subject_contains','請求書', true, 'invoice_attachment', 10, '件名に請求書＋添付あり'),
  ('subject_contains','請求書', false, 'invoice_notice', 20, '件名に請求書・添付なし（パスワード通知・送付のお知らせ等）'),
  ('subject_contains','領収書', true, 'invoice_attachment', 10, '領収書＋添付あり'),
  ('subject_contains','御請求', true, 'invoice_attachment', 10, '御請求＋添付あり'),
  ('subject_contains','送金分', null, 'sales_deposit', 30, '家賃などの送金報告'),
  ('subject_contains','加盟店入金', null, 'sales_deposit', 30, 'PayPay等の入金'),
  ('subject_contains','応募者', null, 'irrelevant', 90, '採用の応募通知'),
  ('subject_contains','キャンペーン', false, 'irrelevant', 90, '販促メール'),
  ('subject_contains','ログインID', null, 'irrelevant', 90, 'アカウント通知'),
  ('subject_contains','アカウント開設', null, 'irrelevant', 90, 'アカウント通知')
) as v(rule_type, pattern, needs_attachment, category, priority, note)
where not exists (select 1 from public.invoice_mail_rules);

-- 分類AIのモデル名としきい値（automation_rule_settings＝モデル名はここで切替可）
insert into public.automation_rule_settings (key, label, description, enabled, action, params) values
  ('email_classify_ai', 'メール自動分類AI', '規則で決まらないメールをAIで分類する。まず軽量モデル、確信度がしきい値未満なら上位モデルで再判定、それでも低ければ要確認。モデル名はparamsで切替。', true, 'auto_candidate',
   '{"model_fast":"claude-haiku-5-5","model_strong":"claude-sonnet-5-5","min_confidence":0.7}'::jsonb)
on conflict (key) do nothing;
