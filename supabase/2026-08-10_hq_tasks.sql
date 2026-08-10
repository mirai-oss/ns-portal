-- ============================================================
-- 本部タスクボード（フェーズ3d／機能⑩）
-- 画面=ポータル（tasks.html）／データ=ハブ。日報の既存tasksとは別物・無変更。
-- テーブルはすべて hq_ 接頭辞の新規。既存テーブルへの変更なし。冪等。
-- 設計書: docs/本部タスクボード設計書.html v1.2 が仕様の正
-- ============================================================

-- ---- 管理権限判定（マスター or 社長/本部） ----
create or replace function hq_can_manage() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select (u.is_master or u.role in ('CEO','HQ'))
     from users u where u.id = auth.uid() and u.is_active),
    false
  );
$$;

-- ---- テンプレート（繰り返しのひな形） ----
create table if not exists hq_task_templates (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  corp text not null check (corp in ('LiveGate','SK','N-Style','トーホー')),
  freq text not null check (freq in ('daily','weekly','monthly','once')),
  weekly_dow int check (weekly_dow between 0 and 6),      -- freq='weekly'（0=日〜6=土）
  monthly_dom int check (monthly_dom between 1 and 31),   -- freq='monthly'
  due_offset_days int not null default 0,                 -- 対象日から期限までのオフセット(日)
  notes text not null default '',                          -- ⚠️注意事項の既定
  visibility text not null default 'all' check (visibility in ('all','members')),
  alert_before3 boolean not null default true,
  alert_before1 boolean not null default true,
  alert_due boolean not null default true,
  alert_overdue_daily boolean not null default true,
  alert_recipient text not null default 'assignee' check (alert_recipient in ('assignee','creator','custom')),
  alert_extra_user_ids uuid[] not null default '{}',
  alert_channels text[] not null default '{inapp}',        -- inapp / lark
  is_active boolean not null default true,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 工程のひな形（テンプレに紐づく。頻度=dailyのときは子チェック定義として使う）
create table if not exists hq_task_template_steps (
  id uuid primary key default gen_random_uuid(),
  template_id uuid not null references hq_task_templates(id) on delete cascade,
  title text not null,
  assignee_id uuid references users(id),      -- null可（毎日タスクの子チェック等、誰でも実施可）
  offset_days int not null default 0,          -- 対象日からの工程期限オフセット(日)
  sort_order int not null default 100,
  kind text not null default 'step' check (kind in ('step','check')),
  store_scope text check (store_scope in ('active','all')),  -- kind='check'かつ店舗別展開のとき（active=直営／all=委託含む全店）
  is_binary boolean not null default false,     -- 2択（OK・異常あり）
  requires_photo boolean not null default false,
  created_at timestamptz not null default now()
);

-- ---- タスク本体（毎日・毎月分など1回ごとに1行、単発も含む） ----
create table if not exists hq_tasks (
  id uuid primary key default gen_random_uuid(),
  template_id uuid references hq_task_templates(id) on delete set null,
  title text not null,
  corp text not null check (corp in ('LiveGate','SK','N-Style','トーホー')),
  freq text not null check (freq in ('daily','weekly','monthly','once')),
  target_date date not null,                    -- 対象日（8/5分などの基準日）
  due_date date,                                 -- 期限（期限内かどうかは保存せず都度計算）
  status text not null default 'todo' check (status in ('todo','doing','done')),
  notes text not null default '',
  visibility text not null default 'all' check (visibility in ('all','members')),
  completed_at timestamptz,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (template_id, target_date)
);
create index if not exists hq_tasks_status_idx on hq_tasks (status, due_date);
create index if not exists hq_tasks_target_idx on hq_tasks (target_date);

-- 公開範囲=members のときの指定者リスト（テンプレ or タスクのどちらかに紐づく）
create table if not exists hq_task_members (
  id uuid primary key default gen_random_uuid(),
  template_id uuid references hq_task_templates(id) on delete cascade,
  task_id uuid references hq_tasks(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  created_at timestamptz not null default now(),
  check ((template_id is not null)::int + (task_id is not null)::int = 1)
);

-- ---- 工程・子チェック（タスクの実体） ----
create table if not exists hq_task_steps (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references hq_tasks(id) on delete cascade,
  template_step_id uuid references hq_task_template_steps(id) on delete set null,
  title text not null,
  assignee_id uuid references users(id),
  due_date date,
  sort_order int not null default 100,
  kind text not null default 'step' check (kind in ('step','check')),
  is_binary boolean not null default false,
  requires_photo boolean not null default false,
  store_id uuid references stores(id),           -- 店舗別チェックのとき
  judgement text check (judgement in ('ok','issue')),
  issue_note text,
  completed_at timestamptz,
  completed_by uuid references users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (judgement is distinct from 'issue' or (issue_note is not null and length(trim(issue_note)) > 0))
);
create index if not exists hq_task_steps_task_idx on hq_task_steps (task_id, sort_order);
create index if not exists hq_task_steps_assignee_idx on hq_task_steps (assignee_id);

-- 公開範囲・担当を考慮した「このタスクが見えるか」判定（RLSから使う）
create or replace function hq_task_visible(t_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select
      hq_can_manage()
      or (t.visibility = 'all'
          and exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.role = 'TEAM'))
      or exists (select 1 from hq_task_members m where m.task_id = t.id and m.user_id = auth.uid())
      or (t.template_id is not null
          and exists (select 1 from hq_task_members m where m.template_id = t.template_id and m.user_id = auth.uid()))
      or exists (select 1 from hq_task_steps s where s.task_id = t.id and s.assignee_id = auth.uid())
    from hq_tasks t where t.id = t_id
  ), false);
$$;

-- 自己参照なしの可視判定（hq_tasks自身のSELECT方針専用）
-- 注: 上のhq_task_visible(id)のように自テーブルをidで再クエリする関数をINSERT ... RETURNINGの
-- SELECT方針に使うと、新規行がその内部サブクエリから見えずRLS拒否になることがある（実機検証済み）。
-- そのためhq_tasks自身のSELECT方針だけは行の列を直接渡すこの関数を使う。他テーブルの方針は
-- 別テーブル(hq_tasks)を参照するだけなのでこの問題は起きず、hq_task_visible(task_id)のままでよい。
create or replace function hq_task_visible_self(t_id uuid, t_visibility text, t_template_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select
    hq_can_manage()
    or (t_visibility = 'all'
        and exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.role = 'TEAM'))
    or exists (select 1 from hq_task_members m where m.task_id = t_id and m.user_id = auth.uid())
    or (t_template_id is not null
        and exists (select 1 from hq_task_members m where m.template_id = t_template_id and m.user_id = auth.uid()))
    or exists (select 1 from hq_task_steps s where s.task_id = t_id and s.assignee_id = auth.uid());
$$;

-- ---- 写真（タスク or 工程のどちらかに紐づく。既存バケット report-photos を流用） ----
create table if not exists hq_task_photos (
  id uuid primary key default gen_random_uuid(),
  task_id uuid references hq_tasks(id) on delete cascade,
  step_id uuid references hq_task_steps(id) on delete cascade,
  storage_path text not null,
  uploaded_by uuid references users(id),
  created_at timestamptz not null default now(),
  check (task_id is not null or step_id is not null)
);
create or replace function hq_task_photo_visible(p_task_id uuid, p_step_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when p_task_id is not null then hq_task_visible(p_task_id)
    when p_step_id is not null then hq_task_visible((select task_id from hq_task_steps where id = p_step_id))
    else false end;
$$;

-- 非管理者は完了関連の列だけ変更可・完了時のルール（判定必須・写真必須）を強制
create or replace function hq_task_step_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not hq_can_manage() then
    if new.task_id <> old.task_id or new.title <> old.title or new.kind <> old.kind
       or coalesce(new.assignee_id::text,'') <> coalesce(old.assignee_id::text,'')
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
drop trigger if exists trg_hq_task_step_before_update on hq_task_steps;
create trigger trg_hq_task_step_before_update before update on hq_task_steps
for each row execute function hq_task_step_before_update();

-- 親タスクの状態を工程の消化状況から自動計算（全工程完了で自動完了）
create or replace function hq_task_recalc_status() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_task_id uuid := coalesce(new.task_id, old.task_id);
  v_total int; v_done int;
begin
  select count(*), count(*) filter (where completed_at is not null) into v_total, v_done
  from hq_task_steps where task_id = v_task_id;
  if v_total > 0 and v_total = v_done then
    update hq_tasks set status='done', completed_at = now(), updated_at = now()
      where id = v_task_id and status <> 'done';
  elsif v_done > 0 then
    update hq_tasks set status='doing', updated_at = now()
      where id = v_task_id and status = 'todo';
  else
    update hq_tasks set status='todo', completed_at = null, updated_at = now()
      where id = v_task_id and status <> 'todo';
  end if;
  return null;
end;
$$;
drop trigger if exists trg_hq_task_recalc on hq_task_steps;
create trigger trg_hq_task_recalc after insert or update or delete on hq_task_steps
for each row execute function hq_task_recalc_status();

-- ---- 添付リンク（url / manual / credential） ----
create table if not exists hq_task_links (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references hq_tasks(id) on delete cascade,
  kind text not null check (kind in ('url','manual','credential')),
  label text not null,
  url text,               -- kind='url'
  manual_ref text,        -- kind='manual'（フェーズ3cのマニュアルID。未接続の間は任意メモ）
  credential_ref text,    -- kind='credential'（社内情報管理の金庫キー・ラベルのみ。値は持たない）
  created_by uuid references users(id),
  created_at timestamptz not null default now()
);

-- ---- タスク個別のアラート上書き ----
create table if not exists hq_task_alerts (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references hq_tasks(id) on delete cascade,
  before3 boolean not null default true,
  before1 boolean not null default true,
  due boolean not null default true,
  overdue_daily boolean not null default true,
  recipient text not null default 'assignee' check (recipient in ('assignee','creator','custom')),
  extra_user_ids uuid[] not null default '{}',
  channels text[] not null default '{inapp}',
  created_at timestamptz not null default now(),
  unique (task_id)
);

-- ---- 履歴（誰が・いつ・何をしたか） ----
create table if not exists hq_task_activity (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references hq_tasks(id) on delete cascade,
  step_id uuid references hq_task_steps(id) on delete set null,
  actor_id uuid references users(id),           -- null=自動（生成・アラート等）
  kind text not null check (kind in ('create','step_complete','step_reopen','comment','photo','alert','stalled')),
  detail text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists hq_task_activity_task_idx on hq_task_activity (task_id, created_at desc);

-- ---- 日次生成の重複防止ログ ----
create table if not exists hq_generation_log (
  id uuid primary key default gen_random_uuid(),
  work_date date not null unique,
  generated_at timestamptz not null default now(),
  generated_by uuid references users(id),
  task_count int not null default 0
);

-- ---- 通知先チャンネル（Lark Webhookはここに保存。コード埋め込み禁止） ----
create table if not exists hq_notify_channels (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kind text not null check (kind in ('lark_webhook','inapp')),
  webhook_url text,       -- kind='lark_webhook'のみ
  keyword text,            -- Larkカスタムボットのキーワード要件対応
  is_default boolean not null default false,
  is_active boolean not null default true,
  created_by uuid references users(id),
  created_at timestamptz not null default now()
);

-- ---- 通知ルール ----
create table if not exists hq_notify_rules (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  target_corp text check (target_corp in ('LiveGate','SK','N-Style','トーホー')),  -- null=すべて
  target_freq text check (target_freq in ('daily','weekly','monthly','once')),      -- null=すべて
  target_template_id uuid references hq_task_templates(id) on delete cascade,       -- null=すべて
  event text not null check (event in ('due_alert','stalled','step_complete','issue_reported')),
  channel_ids uuid[] not null default '{}',
  sort_order int not null default 100,
  is_active boolean not null default true,
  created_by uuid references users(id),
  created_at timestamptz not null default now()
);

-- ---- アプリ内通知（ベル。既存 notifications は日報用なので触らず新設） ----
create table if not exists hq_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references users(id) on delete cascade,
  task_id uuid references hq_tasks(id) on delete cascade,
  kind text not null check (kind in ('due_alert','stalled','step_complete','issue_reported')),
  title text not null,
  body text not null default '',
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists hq_notifications_recipient_idx on hq_notifications (recipient_id, read_at, created_at desc);

-- ============================================================
-- RLS
-- ============================================================
alter table hq_task_templates enable row level security;
alter table hq_task_template_steps enable row level security;
alter table hq_tasks enable row level security;
alter table hq_task_members enable row level security;
alter table hq_task_steps enable row level security;
alter table hq_task_links enable row level security;
alter table hq_task_photos enable row level security;
alter table hq_task_alerts enable row level security;
alter table hq_task_activity enable row level security;
alter table hq_generation_log enable row level security;
alter table hq_notify_channels enable row level security;
alter table hq_notify_rules enable row level security;
alter table hq_notifications enable row level security;

-- テンプレート: 閲覧=本部系(マスター/社長/本部/チーム長)／編集=マスター・社長・本部のみ
drop policy if exists hqtpl_read on hq_task_templates;
create policy hqtpl_read on hq_task_templates for select using (
  hq_can_manage() or exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.role = 'TEAM')
);
drop policy if exists hqtpl_write on hq_task_templates;
create policy hqtpl_write on hq_task_templates for all using (hq_can_manage()) with check (hq_can_manage());

drop policy if exists hqtplstep_read on hq_task_template_steps;
create policy hqtplstep_read on hq_task_template_steps for select using (
  hq_can_manage() or exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.role = 'TEAM')
);
drop policy if exists hqtplstep_write on hq_task_template_steps;
create policy hqtplstep_write on hq_task_template_steps for all using (hq_can_manage()) with check (hq_can_manage());

-- タスク本体: 閲覧=hq_task_visible／作成・削除=マスター・社長・本部のみ／更新=マスター・社長・本部のみ（完了は工程トリガー経由）
drop policy if exists hqt_read on hq_tasks;
create policy hqt_read on hq_tasks for select using (hq_task_visible_self(id, visibility, template_id));
drop policy if exists hqt_insert on hq_tasks;
create policy hqt_insert on hq_tasks for insert with check (hq_can_manage());
drop policy if exists hqt_update on hq_tasks;
create policy hqt_update on hq_tasks for update using (hq_can_manage()) with check (hq_can_manage());
drop policy if exists hqt_delete on hq_tasks;
create policy hqt_delete on hq_tasks for delete using (hq_can_manage());

drop policy if exists hqmem_read on hq_task_members;
create policy hqmem_read on hq_task_members for select using (hq_can_manage() or user_id = auth.uid());
drop policy if exists hqmem_write on hq_task_members;
create policy hqmem_write on hq_task_members for all using (hq_can_manage()) with check (hq_can_manage());

-- 工程・子チェック: 閲覧=hq_task_visible／作成削除=マスター・社長・本部／更新=担当者本人 or 誰でも(assignee無しのcheck) or 管理者
drop policy if exists hqs_read on hq_task_steps;
create policy hqs_read on hq_task_steps for select using (hq_task_visible(task_id));
drop policy if exists hqs_insert on hq_task_steps;
create policy hqs_insert on hq_task_steps for insert with check (hq_can_manage());
drop policy if exists hqs_update on hq_task_steps;
create policy hqs_update on hq_task_steps for update using (
  hq_can_manage() or assignee_id = auth.uid() or (assignee_id is null and hq_task_visible(task_id))
) with check (
  hq_can_manage() or assignee_id = auth.uid() or (assignee_id is null and hq_task_visible(task_id))
);
drop policy if exists hqs_delete on hq_task_steps;
create policy hqs_delete on hq_task_steps for delete using (hq_can_manage());

drop policy if exists hqlink_read on hq_task_links;
create policy hqlink_read on hq_task_links for select using (hq_task_visible(task_id));
drop policy if exists hqlink_write on hq_task_links;
create policy hqlink_write on hq_task_links for all using (hq_can_manage()) with check (hq_can_manage());

drop policy if exists hqphoto_read on hq_task_photos;
create policy hqphoto_read on hq_task_photos for select using (hq_task_photo_visible(task_id, step_id));
drop policy if exists hqphoto_insert on hq_task_photos;
create policy hqphoto_insert on hq_task_photos for insert with check (
  uploaded_by = auth.uid() and hq_task_photo_visible(task_id, step_id)
);
drop policy if exists hqphoto_delete on hq_task_photos;
create policy hqphoto_delete on hq_task_photos for delete using (uploaded_by = auth.uid() or hq_can_manage());

drop policy if exists hqalert_read on hq_task_alerts;
create policy hqalert_read on hq_task_alerts for select using (hq_task_visible(task_id));
drop policy if exists hqalert_write on hq_task_alerts;
create policy hqalert_write on hq_task_alerts for all using (hq_can_manage()) with check (hq_can_manage());

drop policy if exists hqact_read on hq_task_activity;
create policy hqact_read on hq_task_activity for select using (hq_task_visible(task_id));
drop policy if exists hqact_insert on hq_task_activity;
create policy hqact_insert on hq_task_activity for insert with check (
  hq_task_visible(task_id) and (actor_id = auth.uid() or (actor_id is null and hq_can_manage()))
);

drop policy if exists hqgl_read on hq_generation_log;
create policy hqgl_read on hq_generation_log for select using (
  hq_can_manage() or exists(select 1 from users u where u.id = auth.uid() and u.is_active and u.role = 'TEAM')
);
drop policy if exists hqgl_write on hq_generation_log;
create policy hqgl_write on hq_generation_log for all using (hq_can_manage()) with check (hq_can_manage());

drop policy if exists hqch_read on hq_notify_channels;
create policy hqch_read on hq_notify_channels for select using (hq_can_manage());
drop policy if exists hqch_write on hq_notify_channels;
create policy hqch_write on hq_notify_channels for all using (hq_can_manage()) with check (hq_can_manage());

drop policy if exists hqrule_read on hq_notify_rules;
create policy hqrule_read on hq_notify_rules for select using (hq_can_manage());
drop policy if exists hqrule_write on hq_notify_rules;
create policy hqrule_write on hq_notify_rules for all using (hq_can_manage()) with check (hq_can_manage());

drop policy if exists hqnotif_read on hq_notifications;
create policy hqnotif_read on hq_notifications for select using (recipient_id = auth.uid() or hq_can_manage());
drop policy if exists hqnotif_update on hq_notifications;
create policy hqnotif_update on hq_notifications for update using (recipient_id = auth.uid()) with check (recipient_id = auth.uid());
drop policy if exists hqnotif_insert on hq_notifications;
create policy hqnotif_insert on hq_notifications for insert with check (hq_can_manage());
drop policy if exists hqnotif_delete on hq_notifications;
create policy hqnotif_delete on hq_notifications for delete using (hq_can_manage());

-- ============================================================
-- 3d-5準備: 期限内完了率の集計ビュー（担当者×月）だけ先に作成
-- 暫定=期限(due_date)と完了日の単純比較。出勤日ベースの遡及判定は3d-5で置き換え予定
-- ============================================================
create or replace view hq_ontime_stats_v with (security_invoker = true) as
select
  s.assignee_id as user_id,
  date_trunc('month', s.due_date)::date as month,
  count(*) filter (where s.completed_at is not null) as completed_count,
  count(*) filter (where s.completed_at is not null and s.completed_at::date <= s.due_date) as ontime_count,
  count(*) filter (where s.is_binary and s.judgement = 'issue') as issue_count
from hq_task_steps s
where s.due_date is not null and s.assignee_id is not null
group by s.assignee_id, date_trunc('month', s.due_date)::date;

-- ============================================================
-- 3d-2: 繰り返しテンプレートからの当日分自動生成
-- サーバーレス方式: tasks.htmlを誰かが開いたときにRPCで呼ぶ。
-- 重複防止は hq_tasks(template_id,target_date) のunique制約が本体（毎回呼んでも
-- 既存分は on conflict do nothing で無視されるだけなので安全・軽量）。
-- hq_generation_log は「いつ何件生成したか」の記録用途のみで、生成の可否は判定しない
-- （以前はwork_dateのunique制約で1日1回に絞っていたが、テンプレート登録前に1回でも
-- 呼ばれると当日ずっと生成されなくなる不具合があったため撤廃）。
-- 権限チェックなしで誰でも呼べる（システムの housekeeping 動作のため）。
-- ============================================================
create or replace function hq_generate_today() returns int
language plpgsql security definer set search_path = public as $$
declare
  v_today date := current_date;
  v_dow int := extract(dow from v_today)::int;
  v_dom int := extract(day from v_today)::int;
  v_tpl record;
  v_task_id uuid;
  v_step record;
  v_store record;
  v_count int := 0;
begin
  for v_tpl in
    select * from hq_task_templates
    where is_active
      and (
        freq = 'daily'
        or (freq = 'weekly' and weekly_dow = v_dow)
        or (freq = 'monthly' and monthly_dom = v_dom)
      )
  loop
    insert into hq_tasks (template_id, title, corp, freq, target_date, due_date, notes, visibility, created_by)
    values (v_tpl.id, v_tpl.title, v_tpl.corp, v_tpl.freq, v_today, v_today + v_tpl.due_offset_days, v_tpl.notes, v_tpl.visibility, v_tpl.created_by)
    on conflict (template_id, target_date) do nothing
    returning id into v_task_id;

    if v_task_id is null then
      continue; -- 同時実行などで既に生成済み
    end if;
    v_count := v_count + 1;

    for v_step in select * from hq_task_template_steps where template_id = v_tpl.id order by sort_order loop
      if v_step.kind = 'check' and v_step.store_scope is not null then
        for v_store in
          select id from stores where (v_step.store_scope = 'all' or is_active) order by sort_order
        loop
          insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, sort_order, kind, is_binary, requires_photo, store_id)
          values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_today + v_step.offset_days, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_store.id);
        end loop;
      else
        insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, sort_order, kind, is_binary, requires_photo)
        values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_today + v_step.offset_days, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo);
      end if;
    end loop;

    insert into hq_task_activity(task_id, actor_id, kind, detail)
    values (v_task_id, null, 'create', '自動生成（' || v_tpl.freq || '）');
  end loop;

  if v_count > 0 then
    insert into hq_generation_log(work_date, generated_by, task_count) values (v_today, auth.uid(), v_count)
      on conflict (work_date) do update set task_count = hq_generation_log.task_count + excluded.task_count, generated_at = now();
  end if;
  return v_count;
end;
$$;

-- ============================================================
-- 3d-3: 通知（期限アラート・停滞）の毎朝チェック
-- tasks.html読み込み時に毎回呼ぶ（生成と違い1日1回には縛らない。
-- hq_notificationsへの同日重複挿入だけ防ぐ）。
-- アプリ内通知(hq_notifications)はここで直接INSERT。
-- Lark送信はSQLから外部HTTPを呼べないため、送るべき先(webhook_url等)を
-- 戻り値として返し、クライアント側でfetchしてPOSTする。
-- ============================================================
create or replace function hq_check_alerts() returns table(webhook_url text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
declare
  v_today date := current_date;
  v_task record;
  v_cur record;
  v_alert record;
  v_recipient uuid;
  v_event text;
  v_title text;
  v_urls text[] := '{}';
  v_kws text[] := '{}';
  v_titles text[] := '{}';
  v_bodies text[] := '{}';
  v_ch record;
  v_stalled_days int;
  v_since timestamptz;
begin
  for v_task in select t.* from hq_tasks t where t.status <> 'done' loop
    select s.* into v_cur from hq_task_steps s where s.task_id=v_task.id and s.completed_at is null order by s.sort_order limit 1;
    if v_cur is null then continue; end if;

    select * into v_alert from hq_task_alerts where task_id = v_task.id;
    v_event := null; v_title := null;

    if v_cur.due_date is not null then
      if v_cur.due_date < v_today and coalesce(v_alert.overdue_daily, (select alert_overdue_daily from hq_task_templates where id=v_task.template_id), true) then
        v_event := 'due_alert'; v_title := '期限超過: ' || v_task.title;
      elsif v_cur.due_date = v_today and coalesce(v_alert.due, (select alert_due from hq_task_templates where id=v_task.template_id), true) then
        v_event := 'due_alert'; v_title := '本日期限: ' || v_task.title;
      elsif v_cur.due_date = v_today + 1 and coalesce(v_alert.before1, (select alert_before1 from hq_task_templates where id=v_task.template_id), true) then
        v_event := 'due_alert'; v_title := '明日期限: ' || v_task.title;
      elsif v_cur.due_date = v_today + 3 and coalesce(v_alert.before3, (select alert_before3 from hq_task_templates where id=v_task.template_id), true) then
        v_event := 'due_alert'; v_title := '期限3日前: ' || v_task.title;
      end if;
    end if;

    if v_event is not null and not exists(
      select 1 from hq_notifications n where n.task_id=v_task.id and n.kind='due_alert' and n.created_at::date = v_today
    ) then
      v_recipient := coalesce(v_cur.assignee_id, v_task.created_by);
      if v_recipient is not null then
        insert into hq_notifications(recipient_id, task_id, kind, title, body) values (v_recipient, v_task.id, 'due_alert', v_title, coalesce(v_cur.title,''));
      end if;
      for v_ch in
        select distinct c.webhook_url, c.keyword from hq_notify_rules r
        join hq_notify_channels c on c.id = any(r.channel_ids)
        where r.is_active and c.is_active and c.kind='lark_webhook' and r.event='due_alert'
          and (r.target_corp is null or r.target_corp=v_task.corp)
          and (r.target_freq is null or r.target_freq=v_task.freq)
          and (r.target_template_id is null or r.target_template_id=v_task.template_id)
      loop
        v_urls := v_urls || v_ch.webhook_url; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || v_title; v_bodies := v_bodies || coalesce(v_cur.title,'');
      end loop;
    end if;

    select s.completed_at into v_since from hq_task_steps s where s.task_id=v_task.id and s.sort_order < v_cur.sort_order order by s.sort_order desc limit 1;
    if v_since is null then v_since := v_task.created_at; end if;
    v_stalled_days := floor(extract(epoch from (now() - v_since))/86400);
    if v_stalled_days >= 3 and coalesce(v_alert.overdue_daily, true) and not exists(
      select 1 from hq_notifications n where n.task_id=v_task.id and n.kind='stalled' and n.created_at::date = v_today
    ) then
      v_recipient := coalesce(v_cur.assignee_id, v_task.created_by);
      if v_recipient is not null then
        insert into hq_notifications(recipient_id, task_id, kind, title, body) values (v_recipient, v_task.id, 'stalled', '停滞: ' || v_task.title, v_stalled_days || '日停止');
      end if;
      for v_ch in
        select distinct c.webhook_url, c.keyword from hq_notify_rules r
        join hq_notify_channels c on c.id = any(r.channel_ids)
        where r.is_active and c.is_active and c.kind='lark_webhook' and r.event='stalled'
          and (r.target_corp is null or r.target_corp=v_task.corp)
          and (r.target_freq is null or r.target_freq=v_task.freq)
          and (r.target_template_id is null or r.target_template_id=v_task.template_id)
      loop
        v_urls := v_urls || v_ch.webhook_url; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || ('停滞: '||v_task.title); v_bodies := v_bodies || (v_stalled_days || '日停止');
      end loop;
    end if;
  end loop;

  return query select u, k, t, b from unnest(v_urls, v_kws, v_titles, v_bodies) as x(u,k,t,b);
end;
$$;

-- イベント駆動の通知（工程完了・異常あり）。工程完了操作の直後にクライアントから呼ぶ。
create or replace function hq_notify_step_event(p_step_id uuid, p_event text) returns table(webhook_url text, keyword text, title text, body text)
language plpgsql security definer set search_path = public as $$
declare
  v_step record; v_task record; v_next record;
  v_title text; v_body text;
  v_urls text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_ch record;
begin
  select * into v_step from hq_task_steps where id = p_step_id;
  if v_step is null then return; end if;
  select * into v_task from hq_tasks where id = v_step.task_id;
  if v_task is null then return; end if;

  if p_event = 'step_complete' then
    v_title := '工程完了: ' || v_task.title;
    v_body := v_step.title || ' が完了しました';
    select * into v_next from hq_task_steps where task_id=v_task.id and completed_at is null order by sort_order limit 1;
    if v_next is not null and v_next.assignee_id is not null then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_next.assignee_id, v_task.id, 'step_complete', 'あなたの番です: '||v_task.title, v_next.title||'をお願いします');
    end if;
  elsif p_event = 'issue_reported' then
    v_title := '異常あり: ' || v_task.title;
    v_body := v_step.title || ' — ' || coalesce(v_step.issue_note,'');
    if v_task.created_by is not null then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_task.created_by, v_task.id, 'issue_reported', v_title, v_body);
    end if;
  else
    return;
  end if;

  for v_ch in
    select distinct c.webhook_url, c.keyword from hq_notify_rules r
    join hq_notify_channels c on c.id = any(r.channel_ids)
    where r.is_active and c.is_active and c.kind='lark_webhook' and r.event=p_event
      and (r.target_corp is null or r.target_corp=v_task.corp)
      and (r.target_freq is null or r.target_freq=v_task.freq)
      and (r.target_template_id is null or r.target_template_id=v_task.template_id)
  loop
    v_urls := v_urls || v_ch.webhook_url; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
  end loop;

  return query select u,k,t,b from unnest(v_urls,v_kws,v_titles,v_bodies) as x(u,k,t,b);
end;
$$;
