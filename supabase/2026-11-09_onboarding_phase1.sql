-- =============================================================
-- 2026-11-09 入社登録ワークフローの Slack 一元管理 Phase 1（DB）
--   承認: 2026-11-09 中山さん（調査報告 docs/調査報告_入社登録Slack一元化_2026-11-08.md の条件付き承認 ①〜⑪）
--   設計の要点:
--     ・人事チャンネルは既存 hq.jinji（C0CFE1Y9HC7）を使う（新規チャンネルは作らない・ID は slack_channels で管理）
--     ・1 人 1 行の onboarding_workflows ＋ 項目ごとの onboarding_items ＋ 監査 onboarding_events（誰が・いつ・何を・変更前後）
--     ・本部タスク「入社登録（○○さん）」は残し、工程②のチェック 4 項目を onboarding_items と双方向に連動（自動処理の完了で ✓／人が ✓ したら項目も完了）
--     ・hq_create_onboarding_task に重複防止（同じ人×同じ法人の未完了タスクがあれば返す）と related_user_id
--     ・賃金は時給(0)・日給(1)・月給(2)。日給は制約と hr_save_wage が弾いていただけなので許可する（店舗別・休日賃金は時給のみ＝従来どおり）
--     ・Slack からの呼び出し（service_role）用に hr_save_wage へ p_actor を追加（操作者の権限は従来と同じ: マスター/CEO/HQ）
--     ・切替フラグ app_settings.onboarding_slack（既定 OFF＝適用しても通知は変わらない。ON は別途承認後に SQL で）
--   この SQL は本番に「適用しただけでは」通知や画面の挙動を変えない（フラグ OFF・新テーブルは空）。
--   適用: python3 scripts/apply_sql.py supabase/2026-11-09_onboarding_phase1.sql [--dry-run]
-- =============================================================

-- -------------------------------------------------------------
-- 0) 切替フラグ（Phase 1 は OFF で入れる）
--    enabled=true にすると hr-wage-notify が Slack 親メッセージ（onboarding-notify open）を作る
--    legacy_wage_text=true の間は従来の「賃金登録をお願いします（準備中）」の文面も送る（段階的切替・両方 true の期間は 2 通になる）
-- -------------------------------------------------------------
insert into public.app_settings(key, value)
select 'onboarding_slack', jsonb_build_object('enabled', false, 'legacy_wage_text', true, 'channel_key', 'hq.jinji', 'note', '2026-11-09 Phase1: enabled を true にすると入社登録の Slack 親メッセージ＋スレッドが動く')
where not exists (select 1 from public.app_settings where key = 'onboarding_slack');

update public.slack_channels
   set purpose = coalesce(purpose, '') || case when coalesce(purpose, '') like '%入社登録ワークフロー%' then '' else '／入社登録ワークフロー（従業員ごとの親メッセージ＋スレッド・2026-11-09 Phase1）' end,
       updated_at = now()
 where channel_key = 'hq.jinji';

-- -------------------------------------------------------------
-- 1) 既存テーブルへの列追加（既存列は変えない）
-- -------------------------------------------------------------
alter table public.applicants add column if not exists hired_at timestamptz;
comment on column public.applicants.hired_at is '採用確定日時（hire_applicant が設定。2026-11-09 以前の行は status_changed_at で代用）';

alter table public.hr_wage_requests add column if not exists workflow_id uuid;
comment on column public.hr_wage_requests.workflow_id is '入社ワークフロー onboarding_workflows.id（Slack 親メッセージ側で賃金が登録されると status=done になる）';

-- 賃金の区分: 0 時給 / 1 日給 / 2 月給（スマレジ wage_apply の division と同じ）。日給は店舗別・休日賃金なし（既存 CHECK employee_wage_settings_check がそのまま守る）
alter table public.employee_wage_settings drop constraint if exists employee_wage_settings_division_check;
alter table public.employee_wage_settings add constraint employee_wage_settings_division_check check (division in (0, 1, 2));

-- -------------------------------------------------------------
-- 2) 新規テーブル
-- -------------------------------------------------------------
create table if not exists public.onboarding_workflows (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid references public.users(id) on delete set null,
  applicant_id       uuid references public.applicants(id) on delete set null,
  invitation_id      uuid references public.invitations(id) on delete set null,
  status             text not null default 'registering'
                     check (status in ('hired_confirmed','form_sent','registering','completed','cancelled')),
  hired_at           timestamptz,
  hire_date          date,
  role               text,
  store_ids          uuid[] not null default '{}'::uuid[],
  contract_id        text,                      -- 主なスマレジ契約（employee_smaregi_links の is_primary）
  smaregi_staff_id   text,
  slack_channel_key  text not null default 'hq.jinji',
  slack_channel_id   text,
  slack_parent_notification_id uuid,            -- notification_deliveries.id（親メッセージ）
  slack_parent_ts    text,                      -- 親メッセージの ts（スレッド投稿に使う）
  hq_task_id         uuid references public.hq_tasks(id) on delete set null,
  cancelled_reason   text check (cancelled_reason is null or cancelled_reason in
                       ('declined_by_person','no_contact_after_hire','dropped_during_registration','company_reason','other')),
  cancel_note        text,
  cancelled_at       timestamptz,
  cancelled_by       uuid,
  completed_at       timestamptz,
  created_by         uuid,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create unique index if not exists onboarding_workflows_user_uq on public.onboarding_workflows(user_id) where user_id is not null;
create unique index if not exists onboarding_workflows_applicant_uq on public.onboarding_workflows(applicant_id) where applicant_id is not null;
create index if not exists onboarding_workflows_status_idx on public.onboarding_workflows(status, updated_at);
comment on table public.onboarding_workflows is '入社ワークフロー（1 人 1 行）。入社手続き（本人登録・賃金・交通費・税・Web明細・連携）だけを管理。初回シフト・初回勤務はシフト側（将来 onboarding_events に first_shift.* で受け取る）';

create table if not exists public.onboarding_items (
  id                 uuid primary key default gen_random_uuid(),
  workflow_id        uuid not null references public.onboarding_workflows(id) on delete cascade,
  item_key           text not null check (item_key in
                       ('join_form','smaregi_staff','wage','commute_check','commute_set','withholding_tax','web_payslip','email','smaregi_account','slack_link')),
  state              text not null default 'pending' check (state in
                       ('pending','running','completed','retry_wait','manual_required','manual_running','cancelled','failed')),
  attempts           int not null default 0,
  next_retry_at      timestamptz,
  last_error         text,
  payload            jsonb,                       -- 最後の結果（例: 賃金なら division/wage/effective_date/wageApplyId/verified）
  hq_task_step_id    uuid references public.hq_task_steps(id) on delete set null,
  hq_checklist_item_id uuid references public.hq_step_checklist_items(id) on delete set null,
  completion_source  text check (completion_source is null or completion_source in ('smaregi_verified','smaregi_unverified','auto','manual_check','manual_step')),
                     -- 完了のしかた: smaregi_verified=スマレジに保存し GET で一致確認済み／smaregi_unverified=保存したが照合できず／auto=システム判定（フォーム・連携など）
                     --              manual_check=本部タスクのチェック欄を人が ✓／manual_step=本部タスクの工程を人が完了。manual_* は「スマレジ反映済み」を意味しない
  completed_at       timestamptz,
  updated_at         timestamptz not null default now(),
  unique (workflow_id, item_key)
);
create index if not exists onboarding_items_state_idx on public.onboarding_items(state, updated_at);
create index if not exists onboarding_items_hq_item_idx on public.onboarding_items(hq_checklist_item_id) where hq_checklist_item_id is not null;

create table if not exists public.onboarding_events (
  id          bigserial primary key,
  workflow_id uuid not null references public.onboarding_workflows(id) on delete cascade,
  item_key    text,
  kind        text not null,                    -- 例: workflow.opened / item.state / wage.saved / wage.synced / wage.sync_failed / slack.parent / hq_task.linked / first_shift.*（将来）
  actor_id    uuid,
  via         text not null default 'auto' check (via in ('slack','nippo','auto','system','hq_task')),
  before      jsonb,
  after       jsonb,
  payload     jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists onboarding_events_wf_idx on public.onboarding_events(workflow_id, created_at);

alter table public.onboarding_workflows enable row level security;
alter table public.onboarding_items     enable row level security;
alter table public.onboarding_events    enable row level security;
-- 読み: 本部・社長・マスター（hq_can_manage）。書き込みは service_role（RPC/EF）だけ＝画面から直接は書かない
drop policy if exists onboarding_workflows_read on public.onboarding_workflows;
create policy onboarding_workflows_read on public.onboarding_workflows for select to authenticated using (public.hq_can_manage());
drop policy if exists onboarding_items_read on public.onboarding_items;
create policy onboarding_items_read on public.onboarding_items for select to authenticated using (public.hq_can_manage());
drop policy if exists onboarding_events_read on public.onboarding_events;
create policy onboarding_events_read on public.onboarding_events for select to authenticated using (public.hq_can_manage());

-- -------------------------------------------------------------
-- 3) 共通: 呼び出し元の判定（service_role か、本部・社長・マスターの本人）
-- -------------------------------------------------------------
create or replace function public.onboarding_is_service()
returns boolean language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'service_role'
$$;
revoke all on function public.onboarding_is_service() from public, anon;

-- 操作者を決める: p_actor（service_role から渡される）か auth.uid()。権限は従来どおり マスター/CEO/HQ
create or replace function public.onboarding_resolve_actor(p_actor uuid)
returns uuid language plpgsql stable as $$
declare v uuid;
begin
  if auth.uid() is not null then
    v := auth.uid();                                    -- ログインしている人が操作者（p_actor は無視＝なりすまし防止）
  elsif public.onboarding_is_service() then
    v := p_actor;                                       -- EF から呼ばれた（Slack の操作者）
  else
    raise exception '認証が必要です';
  end if;
  if v is null then raise exception '操作者が特定できません'; end if;
  if not exists (select 1 from users u where u.id = v and u.is_active and (u.is_master or u.role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  return v;
end $$;
revoke all on function public.onboarding_resolve_actor(uuid) from public, anon;

-- -------------------------------------------------------------
-- 4) hire_applicant 新版: 採用確定日時 hired_at を保存（他は従来どおり）
-- -------------------------------------------------------------
create or replace function public.hire_applicant(p_applicant uuid, p_role text, p_store_ids uuid[] default '{}'::uuid[], p_days integer default 14)
returns text
language plpgsql security definer set search_path to 'public', 'extensions'
as $$
declare a applicants%rowtype; v_token text := encode(extensions.gen_random_bytes(16), 'hex');
begin
  if not has_feature(auth.uid(),'recruit') then raise exception '権限がありません（採用担当のみ）'; end if;
  if p_role not in ('AL','SHAIN','TENCHO','TEAM','HQ') then raise exception '不正な役職です'; end if;
  select * into a from applicants where id = p_applicant for update;
  if not found then raise exception '応募者が見つかりません'; end if;
  insert into invitations (token, role, store_ids, note, created_by, expires_at, applicant_id, applicant_name, applicant_phone)
  values (v_token, p_role, p_store_ids, '応募者: ' || a.name, auth.uid(),
          now() + make_interval(days => greatest(coalesce(p_days,14),1)), a.id, a.name, a.phone);
  update applicants set status = 'hired', status_changed_at = now(), updated_at = now(), invite_token = v_token,
         hired_at = coalesce(hired_at, now())           -- 2026-11-09: 採用確定日時（再発行では最初の日時を残す）
    where id = a.id;
  return v_token;
end $$;

-- -------------------------------------------------------------
-- 5) hq_create_onboarding_task 新版: 重複防止＋related_user_id（既存の 5 引数版は drop して 6 引数版に置き換える。
--    nippo は名前付き引数で呼ぶので、p_user_id を省略した従来の呼び方もこの関数に解決される）
-- -------------------------------------------------------------
drop function if exists public.hq_create_onboarding_task(text, text, text, text, date);
create or replace function public.hq_create_onboarding_task(
  p_name text, p_email text default null, p_corp text default 'トーホー', p_business text default null,
  p_target_date date default current_date, p_user_id uuid default null)
returns uuid
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_task_id uuid; v_assignee uuid; v_step3_id uuid; v_corp text; v_due date; v_actor uuid := auth.uid();
begin
  if v_actor is null and not public.onboarding_is_service() then
    raise exception '認証が必要です';
  end if;
  if v_actor is not null and not exists(select 1 from users u where u.id = v_actor and u.is_active) then
    raise exception '認証が必要です';
  end if;
  if p_name is null or trim(p_name) = '' then raise exception '氏名が必要です'; end if;

  v_due := p_target_date + 1;
  select c.name into v_corp from stores s join corporations c on c.id = s.corporation_id where s.name = p_business and s.is_active limit 1;
  if v_corp is null then v_corp := coalesce(p_corp, 'トーホー'); end if;

  -- 重複防止（2026-11-09）: 同じ人×同じ法人の未完了タスクがあればそれを返す。user_id が無い呼び方は題名×法人×30 日以内で判定
  if p_user_id is not null then
    select id into v_task_id from hq_tasks
     where related_user_id = p_user_id and corp = v_corp and deleted_at is null and status <> 'done'
     order by created_at desc limit 1;
  end if;
  if v_task_id is null then
    select id into v_task_id from hq_tasks
     where title = '入社登録（' || p_name || 'さん）' and corp = v_corp and deleted_at is null and status <> 'done'
       and created_at > now() - interval '30 days'
     order by created_at desc limit 1;
  end if;
  if v_task_id is not null then
    if p_user_id is not null then update hq_tasks set related_user_id = coalesce(related_user_id, p_user_id) where id = v_task_id; end if;
    return v_task_id;
  end if;

  select id into v_assignee from users where name = '青山純' and is_active limit 1;
  if v_assignee is null then select id into v_assignee from users where name = '齋藤　隆治' and is_active limit 1; end if;

  insert into hq_tasks (title, corp, freq, target_date, due_date, notes, description, visibility, created_by, related_user_id)
  values ('入社登録（' || p_name || 'さん）', v_corp, 'once', p_target_date, v_due, '',
          '新入社員: ' || p_name || 'さん' || E'\n' || 'メールアドレス: ' || coalesce(p_email, '（未設定）') || E'\n' || '所属事業所: ' || coalesce(p_business, '（未設定）'),
          'all', v_actor, p_user_id)
  returning id into v_task_id;

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date)
  values (v_task_id, 'メールアドレスを登録（' || coalesce(p_email, '未設定') || '）', v_assignee, 10, 'step', v_due);

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date)
  values (v_task_id, '給与・明細設定を入力', v_assignee, 30, 'step', v_due) returning id into v_step3_id;
  insert into hq_step_checklist_items(step_id, title, sort_order) values
    (v_step3_id, '時給', 10), (v_step3_id, '交通費', 20), (v_step3_id, '源泉所得税の適用', 30), (v_step3_id, '個別Web給与明細表示設定', 40);

  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, action_kind, action_payload, due_date)
  values (v_task_id, 'LINEで登録案内を送る', v_assignee, 40, 'step', 'onboarding_line_guide', jsonb_build_object('name', p_name, 'email', p_email), v_due);

  insert into hq_task_activity(task_id, actor_id, kind, detail)
  values (v_task_id, v_actor, 'create', '入社登録により自動作成（' || p_name || 'さん）');
  return v_task_id;
end $$;
grant execute on function public.hq_create_onboarding_task(text, text, text, text, date, uuid) to authenticated, service_role;

-- -------------------------------------------------------------
-- 6) hr_save_wage 新版: 日給(1) を許可＋p_actor（Slack 経由）。旧 7 引数版は drop（nippo の名前付き呼び出しはこの版に解決される）
-- -------------------------------------------------------------
drop function if exists public.hr_save_wage(uuid, text, integer, uuid, integer, integer, date);
create or replace function public.hr_save_wage(
  p_user uuid, p_contract text, p_division integer, p_store uuid, p_wage integer, p_holiday integer, p_date date, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_id uuid; v_actor uuid; v_before jsonb; v_wf uuid;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_division not in (0, 1, 2) then raise exception '給与形態は時給(0)・日給(1)・月給(2)のいずれかを指定してください'; end if;
  if not exists(select 1 from users where id = p_user) then raise exception '対象の従業員が見つかりません'; end if;
  if not exists(select 1 from smaregi_contracts where contract_id = p_contract and is_active) then raise exception 'スマレジの契約が見つかりません'; end if;
  if p_wage is null or p_wage <= 0 or p_wage > 100000000 then raise exception '金額が不正です'; end if;
  if p_date is null or p_date < date '2000-01-01' then raise exception '適用開始日を指定してください'; end if;
  if p_division = 2 then
    if p_store is not null then raise exception '月給は店舗を指定できません'; end if;
    if extract(day from p_date) <> 1 then raise exception '月給の適用開始日は月初日（1日）にしてください'; end if;
    p_holiday := null;
  end if;
  if p_division = 1 then
    -- スマレジ公式仕様（2026-11-09 確認）: 日給の適用開始日は月初日。事業所別は API 上は可能だが管理システムでは全事業所共通のみ・休日賃金なし
    if p_store is not null then raise exception '日給は店舗を指定できません（全事業所共通）'; end if;
    if extract(day from p_date) <> 1 then raise exception '日給の適用開始日は月初日（1日）にしてください（スマレジの仕様）'; end if;
    if p_wage > 1000000 then raise exception '日給が大きすぎます（%円）', p_wage; end if;
    p_holiday := null;
  end if;
  if p_division = 0 and p_wage > 100000 then raise exception '時給が大きすぎます（%円）。月給は「月給」で入力してください', p_wage; end if;
  if p_store is not null and not exists(select 1 from stores where id = p_store) then raise exception '店舗が見つかりません'; end if;

  select to_jsonb(w) - 'created_at' - 'updated_at' into v_before from employee_wage_settings w
   where w.user_id = p_user and w.contract_id = p_contract and w.division = p_division
     and coalesce(w.store_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(p_store, '00000000-0000-0000-0000-000000000000'::uuid)
     and w.effective_date = p_date;

  insert into employee_wage_settings(user_id, contract_id, division, store_id, wage, holiday_wage, effective_date, created_by)
  values (p_user, p_contract, p_division, p_store, p_wage, p_holiday, p_date, v_actor)
  on conflict (user_id, contract_id, division, coalesce(store_id, '00000000-0000-0000-0000-000000000000'::uuid), effective_date)
  do update set wage = excluded.wage, holiday_wage = excluded.holiday_wage, sync_status = 'pending', sync_error = null, updated_at = now()
  returning id into v_id;

  -- 入社ワークフローがあれば監査に残す（無ければ何もしない）
  select id into v_wf from onboarding_workflows where user_id = p_user;
  if v_wf is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (v_wf, 'wage', 'wage.saved', v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, v_before,
            jsonb_build_object('id', v_id, 'contract_id', p_contract, 'division', p_division, 'store_id', p_store, 'wage', p_wage, 'holiday_wage', p_holiday, 'effective_date', p_date));
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'actor', v_actor);
end $$;
grant execute on function public.hr_save_wage(uuid, text, integer, uuid, integer, integer, date, uuid) to authenticated, service_role;
revoke execute on function public.hr_save_wage(uuid, text, integer, uuid, integer, integer, date, uuid) from public, anon;   -- 旧版と同じ（anon は実行不可）

-- -------------------------------------------------------------
-- 7) onboarding_start: 入社フォーム完了（または本部の代理登録）時に 1 行作る。何度呼んでも同じ行（冪等）
--    本部タスク（hq_tasks）と工程②のチェック 4 項目・工程①メールを項目に紐づける
-- -------------------------------------------------------------
create or replace function public.onboarding_start(p_user uuid, p_source text default 'nippo', p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  u users%rowtype; v_wf onboarding_workflows%rowtype; v_created boolean := false;
  v_prof record; v_inv record; v_link record; v_task uuid; v_step uuid; v_item uuid; v_stores uuid[];
  v_actor uuid; v_hired timestamptz; v_applicant uuid;
begin
  -- 呼び出し元: service_role（EF）か、本部・社長・マスター本人、または登録した本人（入社フォーム直後に自分の分だけ）
  if auth.uid() is not null then
    if auth.uid() <> p_user and not exists (select 1 from users x where x.id = auth.uid() and x.is_active and (x.is_master or x.role in ('CEO','HQ'))) then
      raise exception '権限がありません';
    end if;
    v_actor := auth.uid();
  elsif public.onboarding_is_service() then
    v_actor := p_actor;
  else
    raise exception '認証が必要です';
  end if;

  select * into u from users where id = p_user;
  if u.id is null then return jsonb_build_object('ok', false, 'error', '従業員が見つかりません'); end if;

  select hire_date, smaregi_staff_id into v_prof from employee_profiles where user_id = p_user;
  select i.id, i.applicant_id into v_inv from invitations i where i.used_by = p_user order by i.used_at desc nulls last limit 1;
  v_applicant := v_inv.applicant_id;
  if v_applicant is null then select id into v_applicant from applicants where user_id = p_user order by status_changed_at desc limit 1; end if;
  if v_applicant is not null then
    select coalesce(hired_at, case when status in ('hired') then status_changed_at end) into v_hired from applicants where id = v_applicant;
  end if;
  select array_agg(us.store_id order by st.sort_order) into v_stores from user_stores us join stores st on st.id = us.store_id where us.user_id = p_user;
  select contract_id, smaregi_staff_id into v_link from employee_smaregi_links
   where user_id = p_user and effective_to is null order by is_primary desc, effective_from desc limit 1;

  select * into v_wf from onboarding_workflows where user_id = p_user;
  if v_wf.id is null then
    insert into onboarding_workflows(user_id, applicant_id, invitation_id, status, hired_at, hire_date, role, store_ids, contract_id, smaregi_staff_id, created_by)
    values (p_user, v_applicant, v_inv.id, 'registering', v_hired, v_prof.hire_date, u.role, coalesce(v_stores, '{}'::uuid[]),
            v_link.contract_id, coalesce(v_link.smaregi_staff_id, v_prof.smaregi_staff_id), v_actor)
    on conflict do nothing
    returning * into v_wf;
    if v_wf.id is null then select * into v_wf from onboarding_workflows where user_id = p_user; else v_created := true; end if;
  else
    -- 既存行: 入社日・契約・スマレジIDが後から埋まった場合だけ追いつかせる（status は変えない）
    update onboarding_workflows set
      hire_date = coalesce(hire_date, v_prof.hire_date), contract_id = coalesce(contract_id, v_link.contract_id),
      smaregi_staff_id = coalesce(smaregi_staff_id, v_link.smaregi_staff_id, v_prof.smaregi_staff_id),
      store_ids = case when cardinality(store_ids) = 0 then coalesce(v_stores, '{}'::uuid[]) else store_ids end, updated_at = now()
    where id = v_wf.id returning * into v_wf;
  end if;

  -- 項目（10 個）を揃える（既にあれば触らない）
  insert into onboarding_items(workflow_id, item_key)
  select v_wf.id, k from unnest(array['join_form','smaregi_staff','wage','commute_check','commute_set','withholding_tax','web_payslip','email','smaregi_account','slack_link']) k
  on conflict (workflow_id, item_key) do nothing;

  -- 自動で分かるものは完了にする（入社フォーム＝この時点で済・スマレジ従業員＝ID があれば済・Slack 連携＝user_slack があれば済）
  update onboarding_items set state = 'completed', completed_at = coalesce(completed_at, now()), completion_source = 'auto', updated_at = now()
   where workflow_id = v_wf.id and state = 'pending' and (
     item_key = 'join_form'
     or (item_key = 'smaregi_staff' and v_wf.smaregi_staff_id is not null)
     or (item_key = 'slack_link' and exists (select 1 from user_slack s where s.user_id = p_user)));

  -- 本部タスクとの紐づけ（related_user_id → 題名の順）
  if v_wf.hq_task_id is null then
    select id into v_task from hq_tasks where related_user_id = p_user and deleted_at is null and status <> 'done' order by created_at desc limit 1;
    if v_task is null then
      select id into v_task from hq_tasks where title = '入社登録（' || u.name || 'さん）' and deleted_at is null and status <> 'done' order by created_at desc limit 1;
    end if;
    if v_task is not null then
      update hq_tasks set related_user_id = coalesce(related_user_id, p_user) where id = v_task;
      update onboarding_workflows set hq_task_id = v_task, updated_at = now() where id = v_wf.id;
      v_wf.hq_task_id := v_task;
      insert into onboarding_events(workflow_id, kind, actor_id, via, payload) values (v_wf.id, 'hq_task.linked', v_actor, 'auto', jsonb_build_object('hq_task_id', v_task));
    end if;
  end if;
  if v_wf.hq_task_id is not null then
    -- 工程②のチェック 4 項目 → 項目へ
    select id into v_step from hq_task_steps where task_id = v_wf.hq_task_id and title = '給与・明細設定を入力' limit 1;
    if v_step is not null then
      update onboarding_items oi set hq_task_step_id = v_step,
             hq_checklist_item_id = (select c.id from hq_step_checklist_items c where c.step_id = v_step and c.title = m.title limit 1), updated_at = now()
        from (values ('wage','時給'), ('commute_set','交通費'), ('withholding_tax','源泉所得税の適用'), ('web_payslip','個別Web給与明細表示設定')) m(item_key, title)
       where oi.workflow_id = v_wf.id and oi.item_key = m.item_key and oi.hq_checklist_item_id is null;
      -- 人が既に ✓ 済みなら項目も完了に
      update onboarding_items oi set state = 'completed', completed_at = coalesce(oi.completed_at, c.checked_at), completion_source = 'manual_check', updated_at = now()
        from hq_step_checklist_items c
       where oi.workflow_id = v_wf.id and oi.hq_checklist_item_id = c.id and c.checked_at is not null and oi.state in ('pending','failed','retry_wait','manual_required');
    end if;
    select id into v_step from hq_task_steps where task_id = v_wf.hq_task_id and title like 'メールアドレスを登録%' limit 1;
    if v_step is not null then
      update onboarding_items set hq_task_step_id = v_step, updated_at = now() where workflow_id = v_wf.id and item_key = 'email' and hq_task_step_id is null;
      update onboarding_items oi set state = 'completed', completed_at = coalesce(oi.completed_at, s.completed_at), completion_source = 'manual_step', updated_at = now()
        from hq_task_steps s where oi.workflow_id = v_wf.id and oi.item_key = 'email' and s.id = v_step and s.completed_at is not null and oi.state = 'pending';
    end if;
  end if;

  if v_created then
    insert into onboarding_events(workflow_id, kind, actor_id, via, payload)
    values (v_wf.id, 'workflow.opened', v_actor, case when p_source = 'nippo' then 'nippo' else 'system' end, jsonb_build_object('source', p_source));
  end if;
  return jsonb_build_object('ok', true, 'created', v_created, 'workflow', to_jsonb(v_wf),
    'items', (select coalesce(jsonb_agg(to_jsonb(i) order by i.item_key), '[]'::jsonb) from onboarding_items i where i.workflow_id = v_wf.id));
end $$;
grant execute on function public.onboarding_start(uuid, text, uuid) to authenticated, service_role;

-- -------------------------------------------------------------
-- 8) onboarding_set_item: 項目の状態を変える唯一の入口（監査・本部タスクのチェック連動・完了判定）
-- -------------------------------------------------------------
create or replace function public.onboarding_set_item(
  p_workflow uuid, p_item text, p_state text, p_payload jsonb default null, p_actor uuid default null, p_via text default 'auto', p_error text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  it onboarding_items%rowtype; v_before jsonb; v_actor uuid; wf onboarding_workflows%rowtype; v_total int; v_done int; v_all_done boolean;
begin
  if auth.uid() is not null then
    v_actor := public.onboarding_resolve_actor(null);
  elsif public.onboarding_is_service() then
    v_actor := p_actor;                                 -- 自動処理は null のこともある
  else
    raise exception '認証が必要です';
  end if;
  if p_state not in ('pending','running','completed','retry_wait','manual_required','manual_running','cancelled','failed') then
    raise exception '不正な状態です: %', p_state;
  end if;
  select * into wf from onboarding_workflows where id = p_workflow for update;
  if wf.id is null then return jsonb_build_object('ok', false, 'error', 'ワークフローが見つかりません'); end if;
  select * into it from onboarding_items where workflow_id = p_workflow and item_key = p_item for update;
  if it.id is null then return jsonb_build_object('ok', false, 'error', '項目が見つかりません: ' || p_item); end if;
  v_before := jsonb_build_object('state', it.state, 'attempts', it.attempts, 'payload', it.payload, 'last_error', it.last_error);

  update onboarding_items set
    state = p_state,
    attempts = case when p_state = 'running' then attempts + 1 else attempts end,
    payload = coalesce(p_payload, payload),
    last_error = case when p_state in ('failed','retry_wait','manual_required') then coalesce(p_error, last_error) when p_state = 'completed' then null else last_error end,
    completed_at = case when p_state = 'completed' then coalesce(completed_at, now()) else null end,
    -- 完了のしかた（手動 ✓ と区別する）: payload.verified が true ならスマレジ照合済み、false ならスマレジ保存のみ、それ以外はシステム判定
    completion_source = case when p_state <> 'completed' then null
                             when coalesce(p_payload, payload) ->> 'verified' = 'true' then 'smaregi_verified'
                             when coalesce(p_payload, payload) ->> 'verified' = 'false' then 'smaregi_unverified'
                             else 'auto' end,
    updated_at = now()
  where id = it.id returning * into it;

  insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after, payload)
  values (p_workflow, p_item, 'item.state', v_actor, coalesce(p_via, 'auto'), v_before,
          jsonb_build_object('state', it.state, 'attempts', it.attempts, 'payload', it.payload, 'last_error', it.last_error), p_payload);

  -- 本部タスク工程②のチェック（自動処理の完了で ✓。人が二重に作業しなくてよいように）
  if p_state = 'completed' and it.hq_checklist_item_id is not null then
    update hq_step_checklist_items set checked_at = coalesce(checked_at, now()), checked_by = coalesce(checked_by, v_actor) where id = it.hq_checklist_item_id;
    if it.hq_task_step_id is not null then
      select count(*), count(*) filter (where checked_at is not null) into v_total, v_done from hq_step_checklist_items where step_id = it.hq_task_step_id;
      if v_total > 0 and v_total = v_done then
        update hq_task_steps set completed_at = coalesce(completed_at, now()), completed_by = coalesce(completed_by, v_actor) where id = it.hq_task_step_id and completed_at is null;
      end if;
    end if;
    if wf.hq_task_id is not null then
      insert into hq_task_activity(task_id, step_id, actor_id, kind, detail)
      values (wf.hq_task_id, it.hq_task_step_id, v_actor, 'comment', '入社ワークフロー: ' || p_item || ' が完了（' || coalesce(p_via, 'auto') || '）');
    end if;
  end if;
  -- 工程①（メール）は項目だけで工程そのものを完了にする
  if p_state = 'completed' and p_item = 'email' and it.hq_task_step_id is not null then
    update hq_task_steps set completed_at = coalesce(completed_at, now()), completed_by = coalesce(completed_by, v_actor) where id = it.hq_task_step_id and completed_at is null;
  end if;
  -- 賃金が入ったら、LINE 返信用の依頼（hr_wage_requests）を閉じる（二重登録防止・段階的切替の一部）
  if p_state = 'completed' and p_item = 'wage' and wf.user_id is not null then
    update hr_wage_requests set status = 'done', done_at = coalesce(done_at, now()), done_by = coalesce(done_by, v_actor), workflow_id = coalesce(workflow_id, wf.id)
     where user_id = wf.user_id and status = 'pending';
  end if;

  -- 完了判定（Phase 1 は「全項目 completed」。cancelled 項目は対象外。入社登録完了と初回勤務は別物＝ここでは勤務を見ない）
  select bool_and(state = 'completed') into v_all_done from onboarding_items where workflow_id = p_workflow and state <> 'cancelled';
  if coalesce(v_all_done, false) and wf.status = 'registering' then
    update onboarding_workflows set status = 'completed', completed_at = now(), updated_at = now() where id = p_workflow;
    insert into onboarding_events(workflow_id, kind, actor_id, via) values (p_workflow, 'workflow.completed', v_actor, 'auto');
  elsif not coalesce(v_all_done, false) and wf.status = 'completed' then
    -- 完了後に項目が戻された: 入社登録完了の履歴（completed_at）は残し、status だけ戻す
    update onboarding_workflows set status = 'registering', updated_at = now() where id = p_workflow;
  end if;
  update onboarding_workflows set updated_at = now() where id = p_workflow;

  return jsonb_build_object('ok', true, 'item', to_jsonb(it), 'workflow_status', (select status from onboarding_workflows where id = p_workflow));
end $$;
grant execute on function public.onboarding_set_item(uuid, text, text, jsonb, uuid, text, text) to authenticated, service_role;

-- -------------------------------------------------------------
-- 9) 人が本部タスクのチェックを ✓ したら、項目も完了にする（双方向・どちらか一方だけ完了の状態を防ぐ）
-- -------------------------------------------------------------
create or replace function public.onboarding_hq_checklist_sync()
returns trigger language plpgsql security definer set search_path to 'public'
as $$
declare it onboarding_items%rowtype;
begin
  select * into it from onboarding_items where hq_checklist_item_id = new.id limit 1;
  if it.id is null then return null; end if;
  if new.checked_at is not null and old.checked_at is null and it.state <> 'completed' then
    -- 人の ✓ ＝ manual_check（スマレジに反映したことを意味しない。表示では「手動 ✓・反映未確認」になる）
    update onboarding_items set state = 'completed', completed_at = coalesce(completed_at, new.checked_at), completion_source = 'manual_check', last_error = null, updated_at = now() where id = it.id;
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (it.workflow_id, it.item_key, 'item.state', coalesce(new.checked_by, auth.uid()), 'hq_task',
            jsonb_build_object('state', it.state), jsonb_build_object('state', 'completed', 'by', 'hq_task_checklist'));
    if (select bool_and(state = 'completed') from onboarding_items where workflow_id = it.workflow_id and state <> 'cancelled') then
      update onboarding_workflows set status = 'completed', completed_at = coalesce(completed_at, now()), updated_at = now() where id = it.workflow_id and status = 'registering';
    end if;
  elsif new.checked_at is null and old.checked_at is not null and it.state = 'completed' then
    -- ✓ を外した: 項目を pending に戻す（自動処理の結果 payload は残す）
    update onboarding_items set state = 'pending', completed_at = null, completion_source = null, updated_at = now() where id = it.id;
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (it.workflow_id, it.item_key, 'item.state', auth.uid(), 'hq_task', jsonb_build_object('state', 'completed'), jsonb_build_object('state', 'pending', 'by', 'hq_task_checklist_unchecked'));
    update onboarding_workflows set status = 'registering', updated_at = now() where id = it.workflow_id and status = 'completed';
  end if;
  return null;
end $$;
drop trigger if exists trg_onboarding_hq_checklist_sync on public.hq_step_checklist_items;
create trigger trg_onboarding_hq_checklist_sync after update of checked_at on public.hq_step_checklist_items
  for each row execute function public.onboarding_hq_checklist_sync();

-- 工程①「メールアドレスを登録」を人が完了/取消したら、項目 email も同じにする（工程単位・チェック欄なし）
create or replace function public.onboarding_hq_step_sync()
returns trigger language plpgsql security definer set search_path to 'public'
as $$
declare it onboarding_items%rowtype;
begin
  select * into it from onboarding_items where hq_task_step_id = new.id and item_key = 'email' limit 1;
  if it.id is null then return null; end if;
  if new.completed_at is not null and old.completed_at is null and it.state <> 'completed' then
    update onboarding_items set state = 'completed', completed_at = coalesce(completed_at, new.completed_at), completion_source = 'manual_step', last_error = null, updated_at = now() where id = it.id;
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (it.workflow_id, 'email', 'item.state', coalesce(new.completed_by, auth.uid()), 'hq_task', jsonb_build_object('state', it.state), jsonb_build_object('state', 'completed', 'by', 'hq_task_step'));
    if (select bool_and(state = 'completed') from onboarding_items where workflow_id = it.workflow_id and state <> 'cancelled') then
      update onboarding_workflows set status = 'completed', completed_at = coalesce(completed_at, now()), updated_at = now() where id = it.workflow_id and status = 'registering';
    end if;
  elsif new.completed_at is null and old.completed_at is not null and it.state = 'completed' then
    update onboarding_items set state = 'pending', completed_at = null, completion_source = null, updated_at = now() where id = it.id;
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (it.workflow_id, 'email', 'item.state', auth.uid(), 'hq_task', jsonb_build_object('state', 'completed'), jsonb_build_object('state', 'pending', 'by', 'hq_task_step_reopened'));
    update onboarding_workflows set status = 'registering', updated_at = now() where id = it.workflow_id and status = 'completed';
  end if;
  return null;
end $$;
drop trigger if exists trg_onboarding_hq_step_sync on public.hq_task_steps;
create trigger trg_onboarding_hq_step_sync after update of completed_at on public.hq_task_steps
  for each row execute function public.onboarding_hq_step_sync();

-- -------------------------------------------------------------
-- 10) 一覧用ビュー（本部・社長・マスターが読める。Slack の親メッセージ再描画にも使う）
-- -------------------------------------------------------------
create or replace view public.onboarding_workflow_v as
select w.*, u.name as user_name, u.email as user_email, u.is_active as user_active,
       (select string_agg(s.name, '・' order by s.sort_order) from stores s where s.id = any(w.store_ids)) as store_names,
       (select jsonb_object_agg(i.item_key, jsonb_build_object('state', i.state, 'attempts', i.attempts, 'last_error', i.last_error, 'payload', i.payload, 'completed_at', i.completed_at, 'completion_source', i.completion_source))
          from onboarding_items i where i.workflow_id = w.id) as items,
       (select c.label from smaregi_contracts c where c.contract_id = w.contract_id limit 1) as contract_label
  from onboarding_workflows w left join users u on u.id = w.user_id;
alter view public.onboarding_workflow_v set (security_invoker = true);
grant select on public.onboarding_workflow_v to authenticated, service_role;

-- -------------------------------------------------------------
-- 11) 既存行の移し替え（適用時には実行しない。確認してから手で実行する）:
--   進行中の入社登録（本部タスクが未完了の人）だけワークフロー行を作る例:
--   select public.onboarding_start(t.related_user_id, 'backfill') from hq_tasks t
--    where t.title like '入社登録（%' and t.deleted_at is null and t.status <> 'done' and t.related_user_id is not null;
--   related_user_id が無い既存タスクは、題名の氏名から users を引いて onboarding_start(user_id,'backfill') を 1 件ずつ。
-- -------------------------------------------------------------
