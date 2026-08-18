-- ============================================================
-- 経費申請（要件定義書v3.2 §20・§22／実装指示書_第3期実装フェーズ §D-1）
-- 画面=expenses.html（新規）／データ=ハブ。既存テーブルは無変更（読むのみ）。
-- 初期版=申請者→承認者の1段階承認。expense_flows/expense_approvalsは
-- 多段フローに拡張できる形で最初から作る（v1のUIは1段のみ使う）。
-- 冪等。
-- ============================================================

-- ---- 勘定科目候補（HQが画面で編集） ----
create table if not exists expense_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  sort_order int not null default 100,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
insert into expense_categories (name, sort_order) values
  ('交通費', 10), ('消耗品費', 20), ('会議費', 30), ('通信費', 40), ('その他', 100)
on conflict (name) do nothing;

-- ---- 承認フロー定義（v1は「1段」の既定フロー1行のみ。将来の多段化用の器） ----
create table if not exists expense_flows (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  step_count int not null default 1,
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
insert into expense_flows (name, step_count, is_default)
select '標準（1段階承認）', 1, true
where not exists (select 1 from expense_flows where is_default);

-- ---- 承認者の自動決定ルール（役職ごとに1行。HQが画面で編集・個人指定の上書きも可） ----
-- approver_mode:
--   team_of_store = 申請者の所属店舗を担当するチーム長（team_stores経由で解決）
--   fixed_role    = 指定した役職の人（複数いる場合は先頭の1人。厳密指定したい場合はfixed_userを使う）
--   fixed_user    = 特定の1人を固定で指定
create table if not exists expense_approver_rules (
  id uuid primary key default gen_random_uuid(),
  applicant_role text not null unique check (applicant_role in ('AL','SHAIN','TENCHO','TEAM','HQ','CEO')),
  approver_mode text not null default 'team_of_store' check (approver_mode in ('team_of_store','fixed_role','fixed_user')),
  fixed_role text check (fixed_role in ('HQ','CEO')),
  fixed_user_id uuid references users(id),
  updated_at timestamptz not null default now()
);
insert into expense_approver_rules (applicant_role, approver_mode, fixed_role) values
  ('AL','team_of_store',null), ('SHAIN','team_of_store',null), ('TENCHO','team_of_store',null),
  ('TEAM','fixed_role','HQ'), ('HQ','fixed_role','CEO')
on conflict (applicant_role) do nothing;

-- ---- 経費申請 本体 ----
create table if not exists expense_requests (
  id uuid primary key default gen_random_uuid(),
  applicant_id uuid not null references users(id),
  use_date date not null,
  amount numeric(12,0) not null check (amount > 0),
  purpose text not null,
  category_id uuid references expense_categories(id),
  store_id uuid references stores(id),
  corporation_id uuid references corporations(id),   -- 共通法人ID（§B）。store_idのcorporation_idを既定値にする（未設定店舗は本社=N-Styleへフォールバック。UI側で解決）
  payment_type text not null default 'tatekae' check (payment_type in ('tatekae')),  -- 会社カード等は将来値追加
  memo text,
  status text not null default 'draft' check (status in ('draft','pending','approved','rejected')),
  flow_id uuid references expense_flows(id),
  approver_id uuid references users(id),             -- 現在の承認者（v1は1段固定）
  applied_at timestamptz,
  decided_at timestamptz,
  reject_reason text,
  task_template_id uuid references hq_task_templates(id),  -- 承認時に生成するタスクのテンプレ（既定はexpense_settingsから複写）
  created_task_id uuid references hq_tasks(id),             -- 承認時に実際に生成したタスク（履歴・二重生成防止）
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists expense_requests_applicant_idx on expense_requests (applicant_id, created_at desc);
create index if not exists expense_requests_approver_idx on expense_requests (approver_id, status);

-- ---- 領収書写真（複数可）。既存report-photosバケットの{uid}/配下ルールに準拠 ----
create table if not exists expense_photos (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references expense_requests(id) on delete cascade,
  storage_path text not null,
  created_by uuid references users(id),
  created_at timestamptz not null default now()
);

-- ---- 承認ステップの実績記録（多段化してもここに積み増すだけで対応できる形） ----
create table if not exists expense_approvals (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references expense_requests(id) on delete cascade,
  step_no int not null default 1,
  approver_id uuid not null references users(id),
  action text not null check (action in ('approved','rejected')),
  comment text,
  acted_at timestamptz not null default now()
);
create index if not exists expense_approvals_request_idx on expense_approvals (request_id, step_no);

-- ---- 経費申請まわりの設定値（v1は「既定のタスクテンプレ」だけを持つ単純なkey-value） ----
create table if not exists expense_settings (
  key text primary key,
  value text,
  updated_at timestamptz not null default now()
);

-- ============================================================
-- 権限判定関数
-- ============================================================
create or replace function expense_can_manage() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select (u.is_master or u.role in ('CEO','HQ')) from users u where u.id = auth.uid() and u.is_active), false);
$$;

-- 申請者の役職→承認者を自動算出（expense_approver_rules準拠）
create or replace function expense_default_approver(p_applicant_id uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare
  v_role text; v_rule record; v_approver uuid;
begin
  select role into v_role from users where id = p_applicant_id and is_active;
  if v_role is null then return null; end if;
  select * into v_rule from expense_approver_rules where applicant_role = v_role;
  if v_rule is null then return null; end if;

  if v_rule.approver_mode = 'fixed_user' then
    return v_rule.fixed_user_id;
  elsif v_rule.approver_mode = 'fixed_role' then
    select id into v_approver from users where role = v_rule.fixed_role and is_active order by created_at limit 1;
    return v_approver;
  elsif v_rule.approver_mode = 'team_of_store' then
    select u.id into v_approver
    from user_stores us
    join team_stores ts on ts.store_id = us.store_id
    join users u on u.team_id = ts.team_id and u.role = 'TEAM' and u.is_active
    where us.user_id = p_applicant_id
    order by us.is_primary desc
    limit 1;
    return v_approver;
  end if;
  return null;
end;
$$;

-- このリクエストを閲覧してよいか（申請者本人／現在の承認者／マスター・CEO・HQ）
create or replace function expense_can_view(p_request_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select applicant_id = auth.uid() or approver_id = auth.uid() or expense_can_manage()
    from expense_requests where id = p_request_id
  ), false);
$$;

-- ============================================================
-- RLS
-- ============================================================
alter table expense_categories enable row level security;
alter table expense_flows enable row level security;
alter table expense_approver_rules enable row level security;
alter table expense_requests enable row level security;
alter table expense_photos enable row level security;
alter table expense_approvals enable row level security;
alter table expense_settings enable row level security;

drop policy if exists excat_read on expense_categories;
create policy excat_read on expense_categories for select using (auth.uid() is not null);
drop policy if exists excat_write on expense_categories;
create policy excat_write on expense_categories for all using (expense_can_manage()) with check (expense_can_manage());

drop policy if exists exflow_read on expense_flows;
create policy exflow_read on expense_flows for select using (auth.uid() is not null);
drop policy if exists exflow_write on expense_flows;
create policy exflow_write on expense_flows for all using (expense_can_manage()) with check (expense_can_manage());

drop policy if exists exrule_read on expense_approver_rules;
create policy exrule_read on expense_approver_rules for select using (auth.uid() is not null);
drop policy if exists exrule_write on expense_approver_rules;
create policy exrule_write on expense_approver_rules for all using (expense_can_manage()) with check (expense_can_manage());

drop policy if exists exset_read on expense_settings;
create policy exset_read on expense_settings for select using (auth.uid() is not null);
drop policy if exists exset_write on expense_settings;
create policy exset_write on expense_settings for all using (expense_can_manage()) with check (expense_can_manage());

-- 申請本体: 閲覧=本人/承認者/管理者。作成=誰でも(自分の申請のみ)。更新=本人のdraftのみ、または管理者。
-- 承認・却下によるstatus変更はRLSのUPDATEでは行わせず、必ずexpense_approve/expense_reject関数(security definer)経由にする
-- （「承認者でない人が承認APIを直叩き→拒否」を関数内チェックで保証するため）。
drop policy if exists exreq_read on expense_requests;
create policy exreq_read on expense_requests for select using (
  applicant_id = auth.uid() or approver_id = auth.uid() or expense_can_manage()
);
drop policy if exists exreq_insert on expense_requests;
create policy exreq_insert on expense_requests for insert with check (applicant_id = auth.uid());
drop policy if exists exreq_update on expense_requests;
create policy exreq_update on expense_requests for update using (
  (applicant_id = auth.uid() and status = 'draft') or expense_can_manage()
) with check (
  (applicant_id = auth.uid() and status = 'draft') or expense_can_manage()
);
drop policy if exists exreq_delete on expense_requests;
create policy exreq_delete on expense_requests for delete using (
  (applicant_id = auth.uid() and status = 'draft') or expense_can_manage()
);

drop policy if exists exphoto_read on expense_photos;
create policy exphoto_read on expense_photos for select using (expense_can_view(request_id));
drop policy if exists exphoto_insert on expense_photos;
create policy exphoto_insert on expense_photos for insert with check (
  created_by = auth.uid() and exists(select 1 from expense_requests r where r.id = request_id and r.applicant_id = auth.uid())
);
drop policy if exists exphoto_delete on expense_photos;
create policy exphoto_delete on expense_photos for delete using (
  created_by = auth.uid() or expense_can_manage()
);

drop policy if exists exappr_read on expense_approvals;
create policy exappr_read on expense_approvals for select using (expense_can_view(request_id));
-- INSERTは直接許可しない（expense_approve/expense_reject関数だけが書き込む）

-- ============================================================
-- 提出・承認・差戻し（RPC。通知の実配信は既存hq_notify基盤と同じ「対象を返してクライアントが送る」方式）
-- ============================================================

-- 下書き→申請中。承認者を自動算出してセットする
create or replace function expense_submit(p_request_id uuid) returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
declare
  v_req record; v_approver uuid; v_flow uuid;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_personal text; v_title text; v_body text; v_applicant_name text;
begin
  select * into v_req from expense_requests where id = p_request_id;
  if v_req is null then raise exception '申請が見つかりません'; end if;
  if v_req.applicant_id <> auth.uid() then raise exception '自分の申請だけ提出できます'; end if;
  if v_req.status <> 'draft' then raise exception 'この申請はすでに提出済みです'; end if;

  v_approver := expense_default_approver(v_req.applicant_id);
  if v_approver is null then
    raise exception '承認者を自動設定できませんでした。本部に承認ルート設定の確認を依頼してください';
  end if;
  select id into v_flow from expense_flows where is_default limit 1;

  update expense_requests set
    status = 'pending', approver_id = v_approver, flow_id = v_flow,
    applied_at = now(), updated_at = now()
  where id = p_request_id;

  select name into v_applicant_name from users where id = v_req.applicant_id;
  v_title := '経費申請の承認をお願いします';
  v_body := coalesce(v_applicant_name,'') || 'さん — ' || v_req.purpose || '（' || v_req.amount::text || '円）';
  insert into hq_notifications(recipient_id, kind, title, body) values (v_approver, 'due_alert', v_title, v_body);

  v_personal := hq_personal_chatwork_room(v_approver);
  if v_personal is not null then
    v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text;
    v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
  end if;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$$;

-- 承認完了。task_template_idからタスクを自動生成し、申請者・タスク担当者へ通知
create or replace function expense_approve(p_request_id uuid, p_comment text default null) returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
declare
  v_req record; v_tpl_id uuid; v_task_id uuid;
  v_step record; v_store record;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_personal text; v_title text; v_body text; v_applicant_name text; v_today date := current_date;
begin
  select * into v_req from expense_requests where id = p_request_id;
  if v_req is null then raise exception '申請が見つかりません'; end if;
  if v_req.status <> 'pending' then raise exception 'この申請は承認待ちではありません'; end if;
  if v_req.approver_id <> auth.uid() and not expense_can_manage() then
    raise exception 'この申請の承認者ではありません';
  end if;

  insert into expense_approvals(request_id, step_no, approver_id, action, comment)
  values (p_request_id, 1, auth.uid(), 'approved', p_comment);

  v_tpl_id := coalesce(v_req.task_template_id, (select value::uuid from expense_settings where key = 'default_task_template_id'));

  if v_tpl_id is not null then
    select name into v_applicant_name from users where id = v_req.applicant_id;
    select * into v_step from hq_task_templates where id = v_tpl_id;
    if v_step is not null then
      insert into hq_tasks (template_id, title, corp, freq, target_date, due_date, due_time, notes, description, visibility, memo, created_by)
      values (v_step.id, v_step.title, v_step.corp, v_step.freq, v_today, v_today + v_step.due_offset_days, v_step.due_time,
              v_step.notes, v_step.description, v_step.visibility,
              '経費申請 #' || substr(p_request_id::text,1,8) || ' ／ ' || coalesce(v_applicant_name,'') || ' ／ ' || v_req.amount::text || '円 ／ ' || v_req.purpose,
              auth.uid())
      on conflict (template_id, target_date) do nothing
      returning id into v_task_id;

      if v_task_id is not null then
        for v_step in select * from hq_task_template_steps where template_id = v_tpl_id order by sort_order loop
          if v_step.kind = 'check' and v_step.store_scope is not null then
            for v_store in
              select id from stores where
                case when v_step.store_ids is not null and array_length(v_step.store_ids,1) > 0 then id = any(v_step.store_ids)
                     else (v_step.store_scope = 'all' or is_active) end
              order by sort_order
            loop
              insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo, store_id)
              values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_today + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_store.id);
            end loop;
          else
            insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo)
            values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_today + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo);
          end if;
        end loop;
        insert into hq_task_activity(task_id, actor_id, kind, detail)
        values (v_task_id, auth.uid(), 'create', '経費申請の承認により自動生成');
      end if;
    end if;
  end if;

  update expense_requests set
    status = 'approved', decided_at = now(), updated_at = now(),
    created_task_id = coalesce(v_task_id, created_task_id)
  where id = p_request_id;

  v_title := '経費申請が承認されました';
  v_body := v_req.purpose || '（' || v_req.amount::text || '円）';
  insert into hq_notifications(recipient_id, kind, title, body) values (v_req.applicant_id, 'due_alert', v_title, v_body);
  v_personal := hq_personal_chatwork_room(v_req.applicant_id);
  if v_personal is not null then
    v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text;
    v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
  end if;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$$;

-- 差戻し（理由必須）
create or replace function expense_reject(p_request_id uuid, p_reason text) returns table(channel_kind text, target text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
declare
  v_req record;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_personal text; v_title text; v_body text;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception '差戻し理由を入力してください';
  end if;
  select * into v_req from expense_requests where id = p_request_id;
  if v_req is null then raise exception '申請が見つかりません'; end if;
  if v_req.status <> 'pending' then raise exception 'この申請は承認待ちではありません'; end if;
  if v_req.approver_id <> auth.uid() and not expense_can_manage() then
    raise exception 'この申請の承認者ではありません';
  end if;

  insert into expense_approvals(request_id, step_no, approver_id, action, comment)
  values (p_request_id, 1, auth.uid(), 'rejected', p_reason);

  update expense_requests set
    status = 'rejected', reject_reason = p_reason, decided_at = now(), updated_at = now()
  where id = p_request_id;

  v_title := '経費申請が差し戻されました';
  v_body := v_req.purpose || '（' || v_req.amount::text || '円） — 理由: ' || p_reason;
  insert into hq_notifications(recipient_id, kind, title, body) values (v_req.applicant_id, 'issue_reported', v_title, v_body);
  v_personal := hq_personal_chatwork_room(v_req.applicant_id);
  if v_personal is not null then
    v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text;
    v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
  end if;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$$;
