-- ============================================================
-- 2026-08-28 担当E: 既存タスクの全体期限バックフィル
--
-- 背景: 工程の期限を編集・追加しても全体期限（hq_tasks.due_date/due_time）が
-- 再計算されない不具合があり（syncTaskDueDate()追加で今後は解消済み・コミット731353f）、
-- その不具合が直っていなかった間に作られた既存タスクは、全体期限が古いまま
-- ズレて残ってしまっている（ユーザー実機報告：「ゴイステック Uber登録」で
-- 全体期限8/27・最終工程9/5のまま）。
--
-- 対応: 「全工程の中でいちばん遅い期限」を全体期限にする、というアプリ側の
-- 既存ルール（submitNewTask・syncTaskDueDate）をSQL側でも一度だけ適用し、
-- 既存タスクの全体期限を今の工程の状態に合わせて是正する（1回限りのバックフィル。
-- スキーマ変更なし・値が既に一致しているタスクは更新対象から自然に除外される）
-- ============================================================

with latest_step as (
  select distinct on (task_id) task_id, due_date, due_time
  from hq_task_steps
  where due_date is not null
  order by task_id, due_date desc, coalesce(due_time, '23:59:59'::time) desc
)
update hq_tasks t
set due_date = ls.due_date,
    due_time = ls.due_time,
    updated_at = now()
from latest_step ls
where t.id = ls.task_id
  and (t.due_date is distinct from ls.due_date or t.due_time is distinct from ls.due_time);
