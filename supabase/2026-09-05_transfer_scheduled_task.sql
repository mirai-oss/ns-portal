-- ============================================================
-- 振込予定日の記録＋本部タスク自動発行（2026-09-05・担当C）
-- ユーザー要望:「PayPay銀行は当日振り込みができないため、振込予定日を振込状態のところに
-- 表示させ、さらに本部タスクを自動発行して振込予定日を期限にタスクが作られるようにしてほしい。
-- 担当は青山純・原美香・齋藤隆治。タスクの工程は振込先の名前（複数ある場合は工程ではなく
-- チェックリストに1つずつ入れる）」
--
-- タスク自動作成の受け皿は、担当Eが入社登録用に作った既存パターン
-- （2026-09-01_hq_onboarding_task.sql の hq_create_onboarding_task）をそのまま踏襲する：
-- hq_tasks 1件＋hq_task_steps 1件（工程）＋hq_step_checklist_items（工程内のチェックリスト、
-- 振込先の名前を1件ずつ）＋hq_task_activity 1件、という構成。
-- ============================================================

-- 取引先向け振込（invoices）：CSV出力時に選んだ振込予定日を記録し、振込一覧・請求書詳細の
-- 「振込状態」欄に表示できるようにする（新しい別テーブルは作らず、既存のtransfer_csv_exported_at
-- と同じ列追加パターンでinvoicesに1列足すだけにする）
alter table invoices add column if not exists transfer_scheduled_date date;

-- 給与振込（payroll）：invoicesのような対象行が無く「その月の給与全体」で1つの予定日になるため、
-- 年月をキーにした小さな専用テーブルを新設する
create table if not exists payroll_transfer_schedule (
  year_month text primary key,           -- 'YYYY-MM'形式
  scheduled_date date not null,
  hq_task_id uuid references hq_tasks(id),
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table payroll_transfer_schedule enable row level security;
drop policy if exists pts_all on payroll_transfer_schedule;
create policy pts_all on payroll_transfer_schedule for all
  using (invoice_can_access()) with check (invoice_can_access());

-- ============================================================
-- hq_create_transfer_task: 振込CSV出力時に呼ぶ、振込確認タスクの自動作成RPC。
-- 担当Eのhq_create_onboarding_taskと同じ構成（タスク1件＋工程1件＋工程内チェックリスト）。
--
-- 引数:
--   p_kind            … 'vendor'（取引先向け請求書の振込）または'payroll'（給与振込）。
--                        タスクのタイトル文言だけを分ける
--   p_transfer_date   … 振込予定日（必須。タスクの期限になる）
--   p_recipient_names … 振込先の名前一覧（取引先名 or 従業員名）。1件ずつチェックリストの
--                        項目になる（工程は分けない、というユーザー指示のとおり）
--   p_corp            … 法人（hq_tasks.corpのCHECK制約に合わせて呼び出し側で正しい値を渡す。
--                        省略時は担当Eのonboardingタスクと同じ既定値'N-Style'）
--
-- 担当: 青山純・原美香・齋藤隆治の3名固定（ユーザー指定）。見つからない人がいても、
-- 見つかった人だけでタスクは必ず作成する（担当Eのonboardingタスクと同じ「タスク自体は
-- 必ず作られる」方針を踏襲）。
-- ============================================================
create or replace function hq_create_transfer_task(
  p_kind text,
  p_transfer_date date,
  p_recipient_names text[],
  p_corp text default 'N-Style'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_task_id uuid;
  v_step_id uuid;
  v_assignees uuid[];
  v_uid uuid;
  v_title text;
  v_name text;
  v_sort int;
begin
  if auth.uid() is null or not exists(select 1 from users u where u.id = auth.uid() and u.is_active) then
    raise exception '認証が必要です';
  end if;
  if p_transfer_date is null then
    raise exception '振込予定日が必要です';
  end if;
  if p_recipient_names is null or array_length(p_recipient_names,1) is null then
    raise exception '振込先の名前が1件も指定されていません';
  end if;

  v_assignees := array[]::uuid[];
  for v_uid in
    select id from users where name in ('青山純','原　美香','齋藤　隆治') and is_active
  loop
    v_assignees := array_append(v_assignees, v_uid);
  end loop;

  v_title := case when p_kind = 'payroll' then '給与振込確認' else '取引先振込確認' end
    || '（振込予定日: ' || to_char(p_transfer_date,'YYYY-MM-DD') || '）';

  insert into hq_tasks (title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
  values (
    v_title, p_corp, 'once', current_date, p_transfer_date, '',
    '振込予定日: ' || to_char(p_transfer_date,'YYYY-MM-DD') || E'\n' ||
    '振込先件数: ' || array_length(p_recipient_names,1) || '件',
    'all', auth.uid()
  ) returning id into v_task_id;

  insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
  values (v_task_id, '振込先を確認', v_assignees, p_transfer_date, 10, 'step')
  returning id into v_step_id;

  v_sort := 10;
  foreach v_name in array p_recipient_names loop
    insert into hq_step_checklist_items(step_id, title, sort_order) values (v_step_id, v_name, v_sort);
    v_sort := v_sort + 10;
  end loop;

  insert into hq_task_activity(task_id, actor_id, kind, detail)
  values (v_task_id, auth.uid(), 'create',
    (case when p_kind='payroll' then '給与振込' else '取引先振込' end) || 'CSV出力により自動作成（振込予定日: ' || to_char(p_transfer_date,'YYYY-MM-DD') || '）');

  return v_task_id;
end;
$$;

grant execute on function hq_create_transfer_task(text, date, text[], text) to authenticated;
