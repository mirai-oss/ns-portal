-- 2026-09-11（担当E）会計・請求ワークスペースUI刷新（司令塔・実装指示書_会計請求ワークスペースUI刷新_2026-09-11.md §1/§9-13）
-- レーンE分担: hq_tasksに「会計の例外だけが本部タスク化される受け皿」を追加する。
--
-- 要求仕様（§9-13原文）: 「本部タスク: 人間が動かないと進まない場合のみ（未取得・金額不一致・
-- 入金差異・AI確信度不足・勘定科目/法人/店舗不明・口座変更・MF登録エラー・振込エラー）。
-- タスクにinvoice_id/receivable_id・発生理由・担当者・期限・元画面リンクを持たせ、
-- 問題解消後は自動完了。本部タスクを会計処理の正本にしない。」
--
-- 設計方針:
-- ・担当・期限は既存のhq_tasks.due_date/hq_task_steps.assignee_idsをそのまま使う（新設しない）
-- ・invoice_id/receivable_id・発生理由・元画面リンクだけを新設する
-- ・「正常処理を本部タスクへ大量発行しない」（§9-12）ため、同じ(invoice_id/receivable_id, 発生理由)の
--   組み合わせで未完了タスクが既にあれば新規作成しない（べき等）
-- ・呼び出し元は①会計ワークスペース(invoices.html)を開いている本部担当者(HQ/CEO/マスター)②
--   Playwright自動取込・MF連携等のサーバー側ジョブ（Edge Function・cron。auth.uid()が無い
--   service_role呼び出し）の両方を想定し、権限チェックはその2パターンだけ許可する
-- ・列追加は宣言制（司令塔指示§20）: このファイルとWORKLOGへの記録をもって宣言とする

-- ①例外連携用の列（invoice_id/receivable_id・発生理由・元画面リンク）
alter table hq_tasks add column if not exists exception_invoice_id uuid references invoices(id);
alter table hq_tasks add column if not exists exception_receivable_id uuid; -- ar_receivables(担当C/D新設予定)。テーブルがまだ無いためFKは付けず、存在後に追加する
alter table hq_tasks add column if not exists exception_reason text;
alter table hq_tasks add column if not exists exception_source_url text;

-- ②種別タブ（TK-52・すべて/入社登録/送金/入金/請求書）用の汎用カテゴリ列。
--   既存の入社登録タスクはタイトル判定(isOnboardingTask)のままにして、後方互換のため
--   ここでは触らない（新規作成分・例外タスクだけがこの列を持つ）
alter table hq_tasks add column if not exists task_category text;

create index if not exists idx_hq_tasks_exception_invoice on hq_tasks(exception_invoice_id) where exception_invoice_id is not null;
create index if not exists idx_hq_tasks_exception_receivable on hq_tasks(exception_receivable_id) where exception_receivable_id is not null;

-- ③例外タスクの発行（べき等）
create or replace function hq_create_exception_task(
  p_title text,
  p_reason text,
  p_corp text,
  p_invoice_id uuid default null,
  p_receivable_id uuid default null,
  p_due_date date default null,
  p_assignee_ids uuid[] default null,
  p_source_url text default null,
  p_category text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_caller users%rowtype;
  v_existing_id uuid;
  v_task_id uuid;
  v_due date;
  v_category text;
begin
  -- 呼び出し元は①会計ワークスペースを開いているHQ/CEO/マスター②サーバー側ジョブ
  -- （auth.uid()が無い＝service_role）のどちらか。anon（一般ユーザーのJWTでauth.uid()は
  -- 取れるがHQ権限が無い場合）はここで弾かれる
  if auth.uid() is not null then
    select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
    if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ')) then
      raise exception '権限がありません（本部担当者のみ）';
    end if;
  end if;

  if p_invoice_id is null and p_receivable_id is null then
    raise exception 'invoice_idまたはreceivable_idのいずれかが必要です';
  end if;
  if p_reason is null or trim(p_reason) = '' then
    raise exception '発生理由（reason）が必要です';
  end if;

  -- べき等: 同じ(invoice_id/receivable_id, 発生理由)で未完了のタスクが既にあれば作り直さない
  select id into v_existing_id from hq_tasks
    where deleted_at is null and status <> 'done' and exception_reason = p_reason
      and ((p_invoice_id is not null and exception_invoice_id = p_invoice_id)
           or (p_receivable_id is not null and exception_receivable_id = p_receivable_id))
    limit 1;
  if v_existing_id is not null then
    return v_existing_id;
  end if;

  v_due := coalesce(p_due_date, current_date + 2); -- 未指定時は検知日+2日（§9-11の発行ルールに準拠）
  v_category := coalesce(p_category, case when p_invoice_id is not null then 'invoice' when p_receivable_id is not null then 'deposit' else null end);

  insert into hq_tasks (title, corp, freq, target_date, due_date, notes, description, visibility, created_by,
    exception_invoice_id, exception_receivable_id, exception_reason, exception_source_url, task_category)
  values (p_title, p_corp, 'once', current_date, v_due, '',
    '会計処理の例外連携により自動発行' || E'\n' || '発生理由: ' || p_reason,
    'all', auth.uid(),
    p_invoice_id, p_receivable_id, p_reason, p_source_url, v_category)
  returning id into v_task_id;

  insert into hq_task_steps(task_id, title, assignee_ids, due_date, sort_order, kind)
  values (v_task_id, '確認・対応する', p_assignee_ids, v_due, 10, 'step');

  insert into hq_task_activity(task_id, actor_id, kind, detail)
  values (v_task_id, auth.uid(), 'create', '会計処理の例外連携により自動発行（' || p_reason || '）');

  return v_task_id;
end;
$$;

grant execute on function hq_create_exception_task(text, text, text, uuid, uuid, date, uuid[], text, text) to authenticated;

-- ④問題解消後の自動完了
create or replace function hq_resolve_exception_task(
  p_invoice_id uuid default null,
  p_receivable_id uuid default null,
  p_reason text default null
) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_caller users%rowtype;
  v_task record;
  v_count int := 0;
begin
  if auth.uid() is not null then
    select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
    if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ')) then
      raise exception '権限がありません（本部担当者のみ）';
    end if;
  end if;
  if p_invoice_id is null and p_receivable_id is null then
    raise exception 'invoice_idまたはreceivable_idのいずれかが必要です';
  end if;

  for v_task in
    select * from hq_tasks
      where deleted_at is null and status <> 'done'
        and (p_reason is null or exception_reason = p_reason)
        and ((p_invoice_id is not null and exception_invoice_id = p_invoice_id)
             or (p_receivable_id is not null and exception_receivable_id = p_receivable_id))
  loop
    -- hq_task_recalc_status（既存トリガー）が全工程完了を見てstatus='done'へ自動的に
    -- 遷移させる設計のため、ここでは工程を完了させるだけにする（status自体は直接触らない）
    update hq_task_steps set completed_at = now() where task_id = v_task.id and completed_at is null;
    insert into hq_task_activity(task_id, actor_id, kind, detail)
      values (v_task.id, auth.uid(), 'comment', '会計処理の例外が解消されたため自動完了');
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

grant execute on function hq_resolve_exception_task(uuid, uuid, text) to authenticated;
