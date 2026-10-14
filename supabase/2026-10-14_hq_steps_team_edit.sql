-- ============================================================
-- 本部タスク: チーム長にも「工程の作成・編集」を許可する（担当E）  作成: 2026-10-14
-- ユーザー要望: 「チーム長が本部タスクを作成はできるが、工程の作成・編集ができない。
--   チーム長までは工程の作成や編集もできるようにしてほしい」
--
-- 【DB変更の事前報告】（ユーザー確認後に適用。未適用の間はこのファイルは設計案）
-- ■なぜ必要か
--   タスクの新規作成は権限設定(hq_feature_allowed('newtask'))でチーム長に開放できているが、
--   工程(hq_task_steps)の追加・編集・削除は従来どおり hq_can_manage()（マスター・社長・本部）
--   固定のため、チーム長が作ったタスクに工程を足せない。
-- ■現在の構造
--   hq_task_steps の insert/delete ポリシー=hq_can_manage()。update ポリシーと
--   hq_task_step_before_update トリガー（担当者以外が工程名・担当・期限などを変えるのを禁止）も
--   hq_can_manage() 以外は不可。工程の添付(hq_task_links/hq_task_photos)の書き込み・
--   工程内チェックリスト(hq_step_checklist_items)の書き込みも同様。
--   hq_tasks の update は hq_can_manage() のみ（全体期限の自動同期が失敗する）。
-- ■変更内容（すべて既存の「機能ごとの権限設定」の仕組みに乗せる）
--   1) hq_feature_permissions に機能 'steps'（工程の作成・編集）を既定 'team'（＋チーム長）で追加。
--      マスターは権限設定画面でいつでも manage/master に戻せる
--   2) 工程のRLS（insert/update/delete）・編集ガードのトリガー・工程チェックリスト・
--      工程の添付(links/photos)の書き込みに「または hq_feature_allowed('steps')」を追加
--   3) 工程の増減・期限変更のあと全体期限を揃える小さなRPC hq_task_sync_due_date を新設
--      （hq_tasks の update 権限は広げず、この関数だけが期限を更新する）
-- ■既存データ・既存機能への影響
--   既存行は無変更。本部/社長/マスターの動作は変わらない（条件を足すだけ）。
--   タスク本体（タイトル・メモ・削除など）の編集権限は広げない。
-- ■rollback
--   delete from hq_feature_permissions where feature='steps';  -- これだけで以前の挙動に戻る
--   （未登録の機能名は hq_feature_allowed が 'manage' 扱いにするため）
--   完全に戻す場合は各ポリシー/関数から「or hq_feature_allowed('steps')」を外す（下の元の式を参照）
--   drop function if exists hq_task_sync_due_date(uuid);
-- ============================================================

insert into hq_feature_permissions(feature, min_level) values ('steps', 'team')
on conflict (feature) do nothing;

-- 工程 insert / delete
drop policy if exists hqs_insert on hq_task_steps;
create policy hqs_insert on hq_task_steps for insert with check (hq_can_manage() or hq_feature_allowed('steps'));
drop policy if exists hqs_delete on hq_task_steps;
create policy hqs_delete on hq_task_steps for delete using (hq_can_manage() or hq_feature_allowed('steps'));

-- 工程 update（元: hq_can_manage() or assignee_id = auth.uid() or auth.uid() = any(assignee_ids)
--              or (assignee_id is null and hq_task_visible(task_id))）
alter policy hqs_update on hq_task_steps
  using (hq_can_manage() or hq_feature_allowed('steps') or assignee_id = auth.uid() or auth.uid() = any(assignee_ids)
         or (assignee_id is null and hq_task_visible(task_id)))
  with check (hq_can_manage() or hq_feature_allowed('steps') or assignee_id = auth.uid() or auth.uid() = any(assignee_ids)
         or (assignee_id is null and hq_task_visible(task_id)));

-- 編集ガードのトリガー（元: if not hq_can_manage() then ... 担当者は完了関連の列だけ変更可）
create or replace function hq_task_step_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not (hq_can_manage() or hq_feature_allowed('steps')) then
    if new.task_id <> old.task_id or new.title <> old.title or new.kind <> old.kind
       or coalesce(new.assignee_id::text,'') <> coalesce(old.assignee_id::text,'')
       or coalesce(new.assignee_ids,'{}'::uuid[]) <> coalesce(old.assignee_ids,'{}'::uuid[])
       or coalesce(new.due_date::text,'') <> coalesce(old.due_date::text,'')
       or coalesce(new.store_id::text,'') <> coalesce(old.store_id::text,'')
       or new.is_binary <> old.is_binary or new.requires_photo <> old.requires_photo then
      raise exception 'この項目は編集できません';
    end if;
  end if;
  if new.completed_at is not null and old.completed_at is null then
    if new.is_binary and new.judgement is null then
      raise exception '判定（OK・異常あり）を選択してください';
    end if;
    if new.requires_photo and not exists (select 1 from hq_task_photos p where p.step_id = new.id) then
      raise exception '写真の添付が必要です';
    end if;
    if new.completed_by is null then new.completed_by := auth.uid(); end if;
  end if;
  if new.completed_at is null then
    new.completed_by := null;
  end if;
  new.updated_at := now();
  return new;
end;
$$;

-- 工程内チェックリスト（元: hq_can_manage() or 担当者 or 担当者なしで閲覧可）
create or replace function hq_step_checklist_can_write(p_step_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from hq_task_steps s
    where s.id = p_step_id
      and (hq_can_manage() or hq_feature_allowed('steps') or s.assignee_id = auth.uid() or auth.uid() = any(s.assignee_ids)
           or (s.assignee_id is null and hq_task_visible(s.task_id)))
  );
$$;

-- 工程の添付（リンク・写真）。タスク全体のリンクは従来どおり管理者のみ（step_idがある行だけ広げる）
drop policy if exists hqlink_write on hq_task_links;
create policy hqlink_write on hq_task_links for all
  using (hq_can_manage() or (step_id is not null and hq_feature_allowed('steps')))
  with check (hq_can_manage() or (step_id is not null and hq_feature_allowed('steps')));
drop policy if exists hqphoto_delete on hq_task_photos;
create policy hqphoto_delete on hq_task_photos for delete using (
  uploaded_by = auth.uid() or hq_can_manage() or (step_id is not null and hq_feature_allowed('steps'))
);

-- 工程の追加・削除・期限変更のあと、全体期限=最終工程の期限に揃える（tasks.htmlのsyncTaskDueDateと同じ規則）
create or replace function hq_task_sync_due_date(p_task_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_due date; v_time time;
begin
  if not (hq_can_manage() or hq_feature_allowed('steps')) then
    raise exception '権限がありません';
  end if;
  if not hq_task_visible(p_task_id) then
    raise exception 'このタスクは操作できません';
  end if;
  select due_date, due_time into v_due, v_time from hq_task_steps
    where task_id = p_task_id and due_date is not null
    order by due_date desc, coalesce(due_time, '23:59'::time) desc limit 1;
  if v_due is null then return; end if;
  update hq_tasks set due_date = v_due, due_time = v_time
    where id = p_task_id and (due_date is distinct from v_due or due_time is distinct from v_time);
end;
$$;
grant execute on function hq_task_sync_due_date(uuid) to authenticated;
