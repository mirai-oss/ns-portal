-- ============================================================
-- 振込確認タスクの重複作成を防ぐ（2026-09-05・担当C）
-- ユーザー報告：「本部タスクに紐付くときに、振込予定日を変更したら、上書きではなく新規で
-- タスクが付いてしまうから、たくさんタスクが付いてしまってる。同じタスクであれば、
-- その上から期日を変えるだけにしてほしい」
--
-- 続き32のhq_create_transfer_taskは呼ぶたびに必ず新規のhq_tasks/hq_task_steps/
-- hq_step_checklist_itemsを作る仕様だったため、振込予定日を直すたびにタスクが増え続けて
-- いた。「同じ対象（kind×scope_key）でまだ開いている（未完了の）タスクがあれば、
-- 新規作成ではなく既存タスクの期限を更新するだけにする」よう作り直す。
--
-- scope_key（「同じタスク」を判定する単位）:
--   kind='vendor'  → 対象法人名（法人ごとに1つの「開いている」振込確認タスクとして扱う）
--   kind='payroll' → 対象年月（'YYYY-MM'。1ヶ月につき1つ）
-- ============================================================

create table if not exists transfer_confirm_task_links (
  kind text not null check (kind in ('vendor','payroll')),
  scope_key text not null,
  hq_task_id uuid not null references hq_tasks(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (kind, scope_key)
);
alter table transfer_confirm_task_links enable row level security;
drop policy if exists tctl_all on transfer_confirm_task_links;
create policy tctl_all on transfer_confirm_task_links for all
  using (invoice_can_access()) with check (invoice_can_access());

create or replace function hq_upsert_transfer_task(
  p_kind text,
  p_scope_key text,
  p_transfer_date date,
  p_recipient_names text[],
  p_corp text default 'N-Style'
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_task_id uuid;
  v_step_id uuid;
  v_task_status text;
  v_assignees uuid[];
  v_uid uuid;
  v_title text;
  v_name text;
  v_sort int;
  v_existing_link record;
begin
  if auth.uid() is null or not exists(select 1 from users u where u.id = auth.uid() and u.is_active) then
    raise exception '認証が必要です';
  end if;
  if p_transfer_date is null then
    raise exception '振込予定日が必要です';
  end if;
  if p_scope_key is null or trim(p_scope_key) = '' then
    raise exception 'scope_keyが必要です';
  end if;
  if p_recipient_names is null or array_length(p_recipient_names,1) is null then
    raise exception '振込先の名前が1件も指定されていません';
  end if;

  v_title := case when p_kind = 'payroll' then '給与振込確認' else '取引先振込確認' end
    || '（振込予定日: ' || to_char(p_transfer_date,'YYYY-MM-DD') || '）';

  -- 既存リンクを確認：同じkind×scope_keyでまだ「未完了」のタスクがあれば、それを更新するだけにする
  select l.hq_task_id, t.status into v_existing_link.hq_task_id, v_task_status
  from transfer_confirm_task_links l join hq_tasks t on t.id = l.hq_task_id
  where l.kind = p_kind and l.scope_key = p_scope_key;

  if v_existing_link.hq_task_id is not null and coalesce(v_task_status,'done') <> 'done' then
    -- ① 既存タスクを更新（期限・タイトルを新しい振込予定日に）
    v_task_id := v_existing_link.hq_task_id;
    update hq_tasks set due_date = p_transfer_date, title = v_title, updated_at = now()
      where id = v_task_id;
    update hq_task_steps set due_date = p_transfer_date, updated_at = now()
      where task_id = v_task_id and sort_order = 10
      returning id into v_step_id;
    -- ② チェックリスト：既に同じ名前があれば追加しない（重複防止）。新しい名前だけ追加する
    v_sort := coalesce((select max(sort_order) from hq_step_checklist_items where step_id = v_step_id), 0) + 10;
    foreach v_name in array p_recipient_names loop
      if not exists (select 1 from hq_step_checklist_items where step_id = v_step_id and title = v_name) then
        insert into hq_step_checklist_items(step_id, title, sort_order) values (v_step_id, v_name, v_sort);
        v_sort := v_sort + 10;
      end if;
    end loop;
    update transfer_confirm_task_links set updated_at = now() where kind = p_kind and scope_key = p_scope_key;
    insert into hq_task_activity(task_id, actor_id, kind, detail)
    values (v_task_id, auth.uid(), 'update', '振込予定日を更新（' || to_char(p_transfer_date,'YYYY-MM-DD') || '）。新規タスクは作成せず既存タスクを更新しました');
    return v_task_id;
  end if;

  -- ③ 既存の開いているタスクが無い（初回、または前回のタスクが完了済み）→ 新規作成
  v_assignees := array[]::uuid[];
  for v_uid in
    select id from users where name in ('青山純','原　美香','齋藤　隆治') and is_active
  loop
    v_assignees := array_append(v_assignees, v_uid);
  end loop;

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

  insert into transfer_confirm_task_links(kind, scope_key, hq_task_id) values (p_kind, p_scope_key, v_task_id)
  on conflict (kind, scope_key) do update set hq_task_id = excluded.hq_task_id, updated_at = now();

  return v_task_id;
end;
$$;

grant execute on function hq_upsert_transfer_task(text, text, date, text[], text) to authenticated;

-- 旧hq_create_transfer_task（続き32）はこの新しいupsert版に置き換わるため、呼び出し側の
-- 更新漏れによる事故を防ぐ目的で、しばらくはそのまま残しつつ新規呼び出しはこちらへ誘導する
comment on function hq_create_transfer_task(text, date, text[], text) is
  '2026-09-05: hq_upsert_transfer_task（scope_key単位で重複作成を防ぐ版）に置き換え。新規実装はそちらを使うこと。';
