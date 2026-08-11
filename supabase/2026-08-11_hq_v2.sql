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

-- ============================================================
-- C-1: タスク内コメント＋@メンション＋通知
-- ============================================================
create table if not exists hq_task_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references hq_tasks(id) on delete cascade,
  body text not null,
  mentions uuid[] not null default '{}',
  created_by uuid references users(id),
  created_at timestamptz not null default now()
);
create index if not exists hq_task_comments_task_idx on hq_task_comments (task_id, created_at);

alter table hq_task_comments enable row level security;
drop policy if exists hqcom_read on hq_task_comments;
create policy hqcom_read on hq_task_comments for select using (hq_task_visible(task_id));
drop policy if exists hqcom_insert on hq_task_comments;
create policy hqcom_insert on hq_task_comments for insert with check (hq_task_visible(task_id) and created_by = auth.uid());
drop policy if exists hqcom_delete on hq_task_comments;
create policy hqcom_delete on hq_task_comments for delete using (created_by = auth.uid());

-- hq_notifications.kind に 'mention' を追加（既存3d-3で作成したCHECK制約を作り直し）
alter table hq_notifications drop constraint if exists hq_notifications_kind_check;
alter table hq_notifications add constraint hq_notifications_kind_check
  check (kind in ('due_alert','stalled','step_complete','issue_reported','mention'));

-- コメント投稿の直後にクライアントから呼ぶ。メンション先へアプリ内通知を作成し、
-- （C-2実装後は）Chatworkの送信対象も戻り値で返す。
create or replace function hq_notify_comment(p_comment_id uuid) returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
declare
  v_com record; v_task record; v_uid uuid;
begin
  select * into v_com from hq_task_comments where id = p_comment_id;
  if v_com is null then return; end if;
  select * into v_task from hq_tasks where id = v_com.task_id;
  if v_task is null then return; end if;

  foreach v_uid in array coalesce(v_com.mentions, '{}') loop
    if v_uid <> v_com.created_by then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_uid, v_task.id, 'mention', 'メンションされました: '||v_task.title, v_com.body);
    end if;
  end loop;

  return query select null::text, null::text, null::text, null::text, null::text where false;
end;
$$;
