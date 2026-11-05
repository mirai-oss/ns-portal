-- 日報画像バケットを非公開にし、期限付き署名 URL でのみ配信する（2026-11-05）
-- 適用: python3 scripts/apply_sql.py supabase/2026-11-05_daily_report_bucket_private.sql
update storage.buckets set public = false where id = 'daily-report';
select id, public, file_size_limit, allowed_mime_types from storage.buckets where id = 'daily-report';
