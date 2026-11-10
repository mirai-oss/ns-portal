-- 振込確認タスクの作成関数 hq_upsert_transfer_task の修正（2026-11-11）
--   ★ 本番未適用（開発・テストのみ承認。適用は別途承認）。戻し方: 2026-09-05_transfer_task_upsert.sql の同じ関数を流し直す（＝元のエラーになる状態に戻る）
--   症状: 振込 CSV を出力しても「振込確認」タスクが作られない（2026-09-05 にこの関数へ切り替えてから、給与・取引先とも 1 件も作られていない。
--         画面には「本部タスクの自動作成に失敗しました（振込CSV自体は正常に作成されています）」と出ていた）
--   原因（2 つ。どちらも関数の中だけ）:
--     ① 既存のリンクを調べる select の結果を、record 型の変数 v_existing_link の「フィールド」に入れていた。
--        値を入れる前の record にはフィールドが無いので、毎回「record "v_existing_link" is not assigned yet」で止まっていた
--     ② 既存のタスクを更新したときの履歴の種類 'update' が、hq_task_activity.kind の制約（create／step_complete／step_reopen／comment／photo／alert／stalled）に無い
--   直し方（最小の差分。処理の流れ・題名・担当・チェック項目・重複防止の考え方は変えていない）:
--     ① 変数を uuid 型の v_existing_task にして、そこへ入れる（4 行）
--     ② 履歴の種類を 'comment' にする（1 行）
--   本番の定義（pg_get_functiondef）から作成し、上の 5 行以外は同一であることを diff で確認済み
CREATE OR REPLACE FUNCTION public.hq_upsert_transfer_task(p_kind text, p_scope_key text, p_transfer_date date, p_recipient_names text[], p_corp text DEFAULT 'N-Style'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_task_id uuid;
  v_step_id uuid;
  v_task_status text;
  v_assignees uuid[];
  v_uid uuid;
  v_title text;
  v_name text;
  v_sort int;
  v_existing_task uuid;   -- 2026-11-11 修正: record 型の変数のフィールドへ、値を入れる前に代入していたため必ずエラーになっていた
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
  select l.hq_task_id, t.status into v_existing_task, v_task_status
  from transfer_confirm_task_links l join hq_tasks t on t.id = l.hq_task_id
  where l.kind = p_kind and l.scope_key = p_scope_key;

  if v_existing_task is not null and coalesce(v_task_status,'done') <> 'done' then
    -- ① 既存タスクを更新（期限・タイトルを新しい振込予定日に）
    v_task_id := v_existing_task;
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
    values (v_task_id, auth.uid(), 'comment', '振込予定日を更新（' || to_char(p_transfer_date,'YYYY-MM-DD') || '）。新規タスクは作成せず既存タスクを更新しました');
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
$function$;
