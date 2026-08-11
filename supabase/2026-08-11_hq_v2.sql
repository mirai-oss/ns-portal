-- ============================================================
-- 本部タスクボード 改善v2（実装指示書v2・14項目対応）
-- 対象: hq_ テーブルのみ変更。既存テーブル・manual_itemsは読取専用。
-- 冪等。
-- ============================================================

-- ---- B-3: タスク削除は作成者のみ（RLSで強制） ----
-- 従来はhq_can_manage()（マスター/社長/本部）なら誰でも削除可だったが、
-- 「削除できるのは作成者だけ」という要求に合わせて限定。
-- テンプレから自動生成されたタスクの created_by はテンプレ作成者
-- （hq_generate_today内でそのまま引き継いでいるので追加対応不要）。
drop policy if exists hqt_delete on hq_tasks;
create policy hqt_delete on hq_tasks for delete using (created_by = auth.uid());
