-- ============================================================
-- 日報へのいいね・コメント通知バッジ用（担当F・2026-09-03）
-- 実行場所: Supabase SQL Editor（何度実行しても壊れません）
--
-- ユーザー要望: 「自分の日報にいいね・フィードバックがあったら、ポータルの
-- 日報メニューに赤い件数バッジが付くようにしてほしい」。既読管理が無いと
-- 一度見ても消えないバッジになってしまうため、ユーザーごとに「ここまでは見た」
-- という時刻だけを覚える最小限のテーブルを1本追加する（1ユーザー1行）。
-- ============================================================

set search_path to public;

create table if not exists report_feedback_seen (
  user_id uuid primary key references users(id) on delete cascade,
  seen_at timestamptz not null default now()
);
comment on table report_feedback_seen is
  'ポータルの日報バッジ用。本人の日報へのいいね・コメントを最後に確認した時刻（1ユーザー1行・upsertのみで運用）';

alter table report_feedback_seen enable row level security;

drop policy if exists rfs_own on report_feedback_seen;
create policy rfs_own on report_feedback_seen for all using (user_id = auth.uid()) with check (user_id = auth.uid());
