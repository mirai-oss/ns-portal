-- 戻し: 同期状況の一覧と不一致照合（2026-11-10_sync_status_overview.sql）を取り消す。既存の各表（申請・同期状態・所属照合）には触れない
drop function if exists hr_sync_status_task_sync(uuid);
drop function if exists hr_sync_mismatch_resolve(uuid, text, uuid);
drop function if exists hr_sync_mismatch_report(text, text, uuid[], jsonb, text, uuid, integer);
drop function if exists hr_sync_status_overview();
drop function if exists hr_sync_status_issues();
drop table if exists employee_sync_task_items;
drop table if exists employee_sync_checks;
drop table if exists employee_sync_mismatches;
update app_settings set value = value - 'sync_task_auto' where key = 'employee_change';
-- ※ 連動で作られた本部タスク（hq_tasks「従業員情報の同期・承認: 要対応の確認」）は残る。不要なら本部タスクボードで完了／削除する
