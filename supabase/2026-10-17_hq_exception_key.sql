-- ============================================================
-- 会計例外タスクの受け口を拡張（担当E・TK-224）  作成: 2026-10-17
-- 実装指示書_請求書自動処理_担当CFE_2026-10-11.md「担当E」＋担当D「スマレジに事業所を作成してください」
--
-- 【DB変更の事前報告】（ユーザー確認後に適用。未適用の間は設計案）
-- ■なぜ必要か
--   現在の hq_create_exception_task / hq_resolve_exception_task は「invoice_id か receivable_id が
--   必須」で、請求書・入金に紐づかない例外（担当Dの「スマレジに事業所を作成してください」＝
--   店舗マスタ側の不足）を、べき等（同じ例外を二重に作らない）に受けられない。
-- ■現在の構造
--   hq_tasks.exception_invoice_id / exception_receivable_id / exception_reason / exception_source_url。
--   二重防止のキーは (invoice_id|receivable_id, reason)。
--   exception_reason は自由記述の text（CHECK制約なし）。担当C(invoice-check)が理由コード8種を
--   すでに渡している。今回の10種（ai_undecided・download_unsupported を含む）もCHECK無しで
--   そのまま入るため、理由コード側のDB変更は不要（画面のラベルはtasks.html/invoices.htmlで定義）。
-- ■変更内容
--   1) hq_tasks に列 exception_key text（請求書・入金以外の例外の識別キー。例: スマレジ事業所名）
--      ＋部分index を追加（NULL許容）
--   2) hq_create_exception_task に末尾の引数 p_key text default null を追加。
--      invoice/receivable/p_key のいずれか1つ以上を必須にし、二重防止は (reason, 同じ対象/キー) で判定。
--      reason='smaregi_store_missing' で担当者が未指定なら、原　美香・青山純・齋藤　隆治の3名を担当にする
--      （既存の請求書例外の挙動＝担当未指定は変えない）
--   3) hq_resolve_exception_task にも p_key を追加（同じ理由・キーのタスクを自動完了）
--   ※引数が増えるため旧シグネチャをdropして作り直す（呼び出しは名前付き引数のJSONなので
--     担当Cのinvoice-checkはそのまま動く）。権限・べき等・自動完了の仕組みは従来どおり。
-- ■既存データ・既存機能への影響
--   既存行は無変更（新列はNULL）。既存の呼び出し（p_keyなし）は従来と同じ結果。
-- ■rollback
--   drop function if exists hq_create_exception_task(text,text,text,uuid,uuid,date,uuid[],text,text,text);
--   drop function if exists hq_resolve_exception_task(uuid,uuid,text,text);
--   drop index if exists idx_hq_tasks_exception_key;
--   alter table hq_tasks drop column if exists exception_key;
--   ※その後 supabase/2026-09-11_hq_task_exception_link.sql の③④を再実行すれば旧関数に戻る
-- ============================================================

alter table hq_tasks add column if not exists exception_key text;
create index if not exists idx_hq_tasks_exception_key on hq_tasks(exception_key) where exception_key is not null;

drop function if exists hq_create_exception_task(text, text, text, uuid, uuid, date, uuid[], text, text);
create or replace function hq_create_exception_task(
  p_title text,
  p_reason text,
  p_corp text,
  p_invoice_id uuid default null,
  p_receivable_id uuid default null,
  p_due_date date default null,
  p_assignee_ids uuid[] default null,
  p_source_url text default null,
  p_category text default null,
  p_key text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_caller users%rowtype;
  v_existing_id uuid;
  v_task_id uuid;
  v_due date;
  v_category text;
  v_assignees uuid[];
  v_key text := nullif(trim(coalesce(p_key, '')), '');
begin
  if auth.uid() is not null then
    select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
    if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ')) then
      raise exception '権限がありません（本部担当者のみ）';
    end if;
  end if;

  if p_invoice_id is null and p_receivable_id is null and v_key is null then
    raise exception 'invoice_id・receivable_id・p_keyのいずれかが必要です';
  end if;
  if p_reason is null or trim(p_reason) = '' then
    raise exception '発生理由（reason）が必要です';
  end if;

  -- べき等: 同じ理由・同じ対象（請求書/入金/キー）で未完了のタスクがあれば作り直さない
  select id into v_existing_id from hq_tasks
    where deleted_at is null and status <> 'done' and exception_reason = p_reason
      and ((p_invoice_id is not null and exception_invoice_id = p_invoice_id)
           or (p_receivable_id is not null and exception_receivable_id = p_receivable_id)
           or (v_key is not null and exception_key = v_key))
    limit 1;
  if v_existing_id is not null then
    return v_existing_id;
  end if;

  v_due := coalesce(p_due_date, current_date + 2);
  v_category := coalesce(p_category,
    case when p_invoice_id is not null then 'invoice'
         when p_receivable_id is not null then 'deposit'
         when p_reason = 'smaregi_store_missing' then 'master'
         else null end);

  v_assignees := p_assignee_ids;
  if v_assignees is null and p_reason = 'smaregi_store_missing' then
    select array_agg(u.id order by case u.name when '原　美香' then 1 when '青山純' then 2 else 3 end)
      into v_assignees from users u where u.is_active and u.name in ('原　美香', '青山純', '齋藤　隆治');
  end if;

  insert into hq_tasks (title, corp, freq, target_date, due_date, notes, description, visibility, created_by,
    exception_invoice_id, exception_receivable_id, exception_reason, exception_source_url, exception_key, task_category)
  values (p_title, p_corp, 'once', current_date, v_due, '',
    '会計処理の例外連携により自動発行' || E'\n' || '発生理由: ' || p_reason,
    'all', auth.uid(),
    p_invoice_id, p_receivable_id, p_reason, p_source_url, v_key, v_category)
  returning id into v_task_id;

  insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
  values (v_task_id, '確認・対応する', v_assignees, v_due, 10, 'step');

  insert into hq_task_activity(task_id, actor_id, kind, detail)
  values (v_task_id, auth.uid(), 'create', '会計処理の例外連携により自動発行（' || p_reason || '）');

  return v_task_id;
end;
$$;
grant execute on function hq_create_exception_task(text, text, text, uuid, uuid, date, uuid[], text, text, text) to authenticated;

drop function if exists hq_resolve_exception_task(uuid, uuid, text);
create or replace function hq_resolve_exception_task(
  p_invoice_id uuid default null,
  p_receivable_id uuid default null,
  p_reason text default null,
  p_key text default null
) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_caller users%rowtype;
  v_task record;
  v_count int := 0;
  v_key text := nullif(trim(coalesce(p_key, '')), '');
begin
  if auth.uid() is not null then
    select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
    if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ')) then
      raise exception '権限がありません（本部担当者のみ）';
    end if;
  end if;
  if p_invoice_id is null and p_receivable_id is null and v_key is null then
    raise exception 'invoice_id・receivable_id・p_keyのいずれかが必要です';
  end if;

  for v_task in
    select * from hq_tasks
      where deleted_at is null and status <> 'done'
        and (p_reason is null or exception_reason = p_reason)
        and ((p_invoice_id is not null and exception_invoice_id = p_invoice_id)
             or (p_receivable_id is not null and exception_receivable_id = p_receivable_id)
             or (v_key is not null and exception_key = v_key))
  loop
    update hq_task_steps set completed_at = now() where task_id = v_task.id and completed_at is null;
    insert into hq_task_activity(task_id, actor_id, kind, detail)
      values (v_task.id, auth.uid(), 'comment', '会計処理の例外が解消されたため自動完了');
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;
grant execute on function hq_resolve_exception_task(uuid, uuid, text, text) to authenticated;
