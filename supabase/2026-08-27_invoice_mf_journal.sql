-- 請求書 → マネーフォワード仕訳登録（2026-08-27）
-- invoicesテーブルに列追加のみ（既存の2026-08-23_invoices.sqlは触らない・新規日付ファイルで追記する方針）
alter table invoices add column if not exists mf_journal_id text;
alter table invoices add column if not exists mf_journal_number bigint;
alter table invoices add column if not exists mf_journal_created_at timestamptz;
