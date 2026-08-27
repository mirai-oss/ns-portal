-- 請求書 ⇔ 本部タスクの工程 紐付け（2026-08-27）
-- ユーザー要望: 「株式会社Aの請求書を処理したら、本部タスクの中の株式会社Aのマネーフォワード入力の
-- 工程タスクが自動で完了になるように」。メール側（invoices.html）でどの工程かを選択できるようにし、
-- 仕訳登録（mf-journal/create）が成功したタイミングで、紐付けた工程を自動完了させる。
-- hq_task_stepsはレーンE（本部タスク）の縄張りだが、列追加のみ・完了処理も既存のRLS/トリガーを
-- そのまま経由する（呼び出し元ユーザー自身のJWTでPATCHする）ため、hq側のロジックは一切変更しない。
alter table invoices add column if not exists linked_hq_step_id uuid references hq_task_steps(id) on delete set null;
create index if not exists invoices_linked_hq_step_idx on invoices (linked_hq_step_id);
