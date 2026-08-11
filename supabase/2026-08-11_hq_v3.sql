-- ============================================================
-- 本部タスクボード v3（実機フィードバック 2026-08-11 その2）
--   1) テンプレートから手動でタスクを追加（hq_create_from_template）
--   4) 機能ごとの権限設定（hq_feature_permissions／マスターのみ変更可）
-- 対象: hq_ テーブルのみ変更。既存テーブル・manual_itemsは読取専用。冪等。
-- ============================================================

-- ============================================================
-- 4) 権限設定: 機能ごとに「誰まで使えるか」をマスターが決められるように
--    min_level: master = マスターのみ
--               manage = マスター・社長・本部（従来の hq_can_manage()）
--               team   = 上記＋チーム長
-- ============================================================
create or replace function hq_is_master() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select u.is_master from users u where u.id = auth.uid() and u.is_active), false);
$$;

create table if not exists hq_feature_permissions (
  feature text primary key,
  min_level text not null default 'manage' check (min_level in ('master','manage','team')),
  updated_at timestamptz not null default now(),
  updated_by uuid references users(id)
);

-- 既定値: 通知設定・法人管理はマスターのみ（今回の要望）。他は従来どおり。
insert into hq_feature_permissions(feature, min_level) values
  ('templates','manage'),   -- ⚙️ テンプレート管理
  ('newtask','manage'),     -- ＋ タスク追加（単発作成・テンプレから追加）
  ('notify','master'),      -- 🔔 通知設定
  ('corps','master')        -- 🏢 法人管理
on conflict (feature) do nothing;

alter table hq_feature_permissions enable row level security;
drop policy if exists hqfp_read on hq_feature_permissions;
create policy hqfp_read on hq_feature_permissions for select using (auth.uid() is not null);
drop policy if exists hqfp_write on hq_feature_permissions;
create policy hqfp_write on hq_feature_permissions for all using (hq_is_master()) with check (hq_is_master());

-- 未登録の機能名は 'manage'（従来の管理者）扱いにフォールバックする
create or replace function hq_feature_allowed(p_feature text) returns boolean
language sql stable security definer set search_path = public as $$
  select case coalesce((select min_level from hq_feature_permissions where feature = p_feature), 'manage')
    when 'master' then hq_is_master()
    when 'team' then coalesce(
      (select (u.is_master or u.role in ('CEO','HQ','TEAM')) from users u where u.id = auth.uid() and u.is_active), false)
    else hq_can_manage()
  end;
$$;

-- ---- 各機能のRLSを権限設定に連動させる ----
-- 通知設定（チャンネル・ルール）
drop policy if exists hqch_read on hq_notify_channels;
create policy hqch_read on hq_notify_channels for select using (hq_feature_allowed('notify'));
drop policy if exists hqch_write on hq_notify_channels;
create policy hqch_write on hq_notify_channels for all using (hq_feature_allowed('notify')) with check (hq_feature_allowed('notify'));

drop policy if exists hqrule_read on hq_notify_rules;
create policy hqrule_read on hq_notify_rules for select using (hq_feature_allowed('notify'));
drop policy if exists hqrule_write on hq_notify_rules;
create policy hqrule_write on hq_notify_rules for all using (hq_feature_allowed('notify')) with check (hq_feature_allowed('notify'));

-- 法人管理（読みは全員のまま。絞り込み表示に使うため）
drop policy if exists hqcorps_write on hq_corps;
create policy hqcorps_write on hq_corps for all using (hq_feature_allowed('corps')) with check (hq_feature_allowed('corps'));

-- テンプレート管理（読みは従来のまま。書きだけ権限設定に連動）
drop policy if exists hqtpl_write on hq_task_templates;
create policy hqtpl_write on hq_task_templates for all using (hq_feature_allowed('templates')) with check (hq_feature_allowed('templates'));
drop policy if exists hqtplstep_write on hq_task_template_steps;
create policy hqtplstep_write on hq_task_template_steps for all using (hq_feature_allowed('templates')) with check (hq_feature_allowed('templates'));

-- タスクの新規作成（単発／テンプレから追加）
drop policy if exists hqt_insert on hq_tasks;
create policy hqt_insert on hq_tasks for insert with check (hq_feature_allowed('newtask'));

-- ============================================================
-- 1) テンプレートから手動でタスクを追加
--    毎日/毎週/毎月の自動生成を待たずに、その場で当月分（対象日を指定）を作る。
--    hq_tasks(template_id, target_date) のunique制約により二重作成は起きない
--    （既にある場合は既存タスクのidを was_created=false で返す）。
--    工程の展開ロジックは hq_generate_today と同一（店舗別チェックのstore_ids対応込み）。
-- ============================================================
create or replace function hq_create_from_template(p_template_id uuid, p_target_date date default null)
returns table(task_id uuid, was_created boolean)
language plpgsql security definer set search_path = public as $$
declare
  v_tpl record;
  v_date date := coalesce(p_target_date, current_date);
  v_task_id uuid;
  v_step record;
  v_store record;
begin
  if not hq_feature_allowed('newtask') then
    raise exception 'タスクを追加する権限がありません';
  end if;

  select * into v_tpl from hq_task_templates where id = p_template_id;
  if v_tpl is null then
    raise exception 'テンプレートが見つかりません';
  end if;

  insert into hq_tasks (template_id, title, corp, freq, target_date, due_date, due_time, notes, description, visibility, created_by)
  values (v_tpl.id, v_tpl.title, v_tpl.corp, v_tpl.freq, v_date, v_date + v_tpl.due_offset_days, v_tpl.due_time,
          v_tpl.notes, v_tpl.description, v_tpl.visibility, coalesce(auth.uid(), v_tpl.created_by))
  on conflict (template_id, target_date) do nothing
  returning id into v_task_id;

  if v_task_id is null then
    select t.id into v_task_id from hq_tasks t where t.template_id = v_tpl.id and t.target_date = v_date;
    return query select v_task_id, false;
    return;
  end if;

  for v_step in select * from hq_task_template_steps where template_id = v_tpl.id order by sort_order loop
    if v_step.kind = 'check' and v_step.store_scope is not null then
      for v_store in
        select id from stores where
          case
            when v_step.store_ids is not null and array_length(v_step.store_ids,1) > 0 then id = any(v_step.store_ids)
            else (v_step.store_scope = 'all' or is_active)
          end
        order by sort_order
      loop
        insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo, store_id)
        values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_date + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_store.id);
      end loop;
    else
      insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo)
      values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_date + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo);
    end if;
  end loop;

  insert into hq_task_activity(task_id, actor_id, kind, detail)
  values (v_task_id, auth.uid(), 'create', 'テンプレートから手動追加（対象日 ' || to_char(v_date,'YYYY-MM-DD') || '）');

  return query select v_task_id, true;
end;
$$;
