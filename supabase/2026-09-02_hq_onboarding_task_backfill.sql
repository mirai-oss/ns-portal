-- 2026-09-02（担当E）既存の入社登録タスクの一括修正（バックフィル）
-- 上記2026-09-02_hq_onboarding_task_corp_and_due.sqlでRPCの今後の挙動は直したが、
-- 既にRPCで自動作成済みの入社登録タスク（すべて誤って法人=N-Styleになっていた）は
-- 直らないため、既存分だけこのSQLで一度だけ直す。
-- 対象は「hq_create_onboarding_task()が作ったタスク」に限定するため、description列が
-- '新入社員: 'で始まるものだけを対象にする（ユーザーが手動で作った同名タスク等を誤って
-- 巻き込まないため）。

-- ①法人を、descriptionに記録済みの「所属事業所」からstores→corporationsを逆引きして修正
with target as (
  select ht.id as task_id,
         trim(substring(ht.description from '所属事業所: (.*)')) as store_name
  from hq_tasks ht
  where ht.description like '新入社員: %'
    and ht.deleted_at is null
),
resolved as (
  select t.task_id, c.name as corp_name
  from target t
  join stores s on s.name = t.store_name and s.is_active
  join corporations c on c.id = s.corporation_id
)
update hq_tasks
set corp = resolved.corp_name
from resolved
where hq_tasks.id = resolved.task_id
  and hq_tasks.corp is distinct from resolved.corp_name;

-- ②工程のdue_dateが未設定のものを、タスク本体のdue_dateで埋める
update hq_task_steps s
set due_date = t.due_date
from hq_tasks t
where s.task_id = t.id
  and t.description like '新入社員: %'
  and t.deleted_at is null
  and s.due_date is null;
