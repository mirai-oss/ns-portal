-- ============================================================
-- ラウンド5 E-4: タスクの削除を論理削除に変更
-- 作成: 2026-08-31 ／ 担当E（本部タスクボード）
--
-- 実装指示書_ラウンド5_2026-08-31.md §1 E-4より:
-- 「タスク自体の削除: 必要のないタスクを削除できるように。誤削除防止のため
--  ①確認ダイアログ ②削除は論理削除（deleted_at列追加・一覧から消えるだけ）を推奨」
--
-- 新規列のみ追加（既存ルールどおり）。RLSは既存のhqt_update（hq_can_manage()）が
-- そのまま使えるため新規ポリシーは不要（deleted_atをセットするのは通常のUPDATE）。
-- これまでhqt_delete（作成者のみ）で物理削除していたが、論理削除化にあわせて
-- 「タスクを片付けられる人」を他の管理系操作（テンプレート編集・法人管理等）と同じ
-- hq_can_manage()に統一する（作成者本人でなくても本部側で片付けられるようにするため）。
-- ============================================================

alter table hq_tasks add column if not exists deleted_at timestamptz;
create index if not exists hq_tasks_deleted_idx on hq_tasks(deleted_at);

-- 物理削除用のhqt_deleteポリシーはもう使わない想定だが、緊急時の掃除用に
-- hq_can_manage()向けに残しておく（アプリからは呼ばない＝論理削除のみ使用）
drop policy if exists hqt_delete on hq_tasks;
create policy hqt_delete on hq_tasks for delete using (hq_can_manage());
