-- Slack 通知の共通部品（開発 5・2026-11-12）: 通知の種類・メンション先の設定と解決・案件の控え・未連携の確認タスク
--   設計: docs/設計書_Slack通知の共通フォーマット_2026-11-11.md
--   ★ 本番未適用（開発・テストのみ承認。適用は別途承認）。戻し方: 2026-11-12_notice_base_rollback.sql
--
--   これは「部品」だけ。適用しても、いま出ている通知は 1 つも変わらない（どの通知も、まだこの部品を呼んでいない。種類の形式の版は全部 1＝旧い形のまま）。
--   足すのは表 5 つ・関数 5 つ・設定の項目 2 つ。既存の表・関数は作り替えない。
--
--   確定している方針（2026-11-11 ユーザー決定）:
--     ・メンション先と承認権限は別に持つ（ここはメンション先だけ。承認権限は approval_routes と既存の権限関数）
--     ・メンションできない人がいても、通知先は広げない。未連携の人については、決めた担当者に確認タスクを作る
--     ・同じ人は 1 回だけ。退職・無効・通知から外す設定の人は除く
--     ・社員には店長を含む。本部メンバーには社長を含む

-- ============ 1. 通知の種類 ============
create table if not exists notice_types (
  type_key          text primary key,
  label             text not null,                 -- 【】の中に出す名前
  emoji             text not null default '',
  channel_key       text not null,                 -- 出す先（slack_channels の鍵）
  final_channel_key text,                          -- 最後の段階だけ別の場所に出すとき（賃金＝社長の最終承認）
  date_rule         text not null default 'event' check (date_rule in ('event', 'work_date')),   -- 親の日付: 申請・発生の日／対象の勤務日
  thread_fields     text[] not null default '{}',  -- スレッドに出してよい項目（金額・口座番号・住所などは入れない）
  format_version    integer not null default 1 check (format_version in (1, 2)),   -- 1=これまでの形／2=共通の形（親 2 行＋スレッド）。切り替えは種類ごと
  sort_order        integer not null default 100,
  updated_at        timestamptz not null default now()
);
insert into notice_types(type_key, label, emoji, channel_key, final_channel_key, date_rule, thread_fields, sort_order) values
  ('attendance_fix', '勤怠確認', '⏰', 'kintai.check', null, 'work_date', '{work_date,store,clock_in,clock_out,reason,status,history}', 10),
  ('onboarding',     '入社登録', '👤', 'hq.jinji', null, 'event', '{hire_date,role,stores,items_status,history}', 20),
  ('retirement',     '退職処理', '🚪', 'hq.jinji', null, 'event', '{retire_date,stores,status,history}', 30),
  ('wage_change',    '賃金変更', '💴', 'hq.jinji', 'hq.juyo_shonin', 'event', '{effective_date,stage,confirmed_by,due,status,history}', 40),
  ('bank_account',   '口座変更', '🏦', 'hq.jinji', null, 'event', '{pay_run,status,history}', 50),
  ('address',        '住所変更', '🏠', 'hq.jinji', null, 'event', '{changed_fields,status,history}', 60),
  ('commute',        '交通費',   '🚃', 'hq.jinji', null, 'event', '{status,history}', 70),
  ('store_transfer', '所属店舗変更', '🔁', 'hq.jinji', null, 'event', '{stores_before,stores_after,effective_date,status,history}', 80),
  ('wage_external',  '賃金・スマレジ直接変更', '⚠️', 'hq.jinji', null, 'event', '{kind,effective_date,status,history}', 90)
on conflict (type_key) do nothing;

-- ============ 2. メンション先の設定（承認権限とは別） ============
--   scene: open＝親メッセージを最初に出すとき／stage:<段階の鍵>＝担当が替わるとき（スレッドへの返信でメンション）
--   targets: 決め方の部品の並び
--     {"kind":"role","roles":["HQ","CEO"]}            その役割の全員
--     {"kind":"store_role","roles":["SHAIN","TENCHO"]}  対象の店舗に所属する、その役割の人
--     {"kind":"store_team_leader"}                    対象の店舗を担当するチームの、チーム長
--     {"kind":"user","user_id":"…"}                   指定した人
--     {"kind":"task_assignee"}                        本部タスクの担当（呼び出し側が渡す。既存の担当者ルールを使う場面）
create table if not exists notice_mention_rules (
  id         uuid primary key default gen_random_uuid(),
  type_key   text not null references notice_types(type_key) on delete cascade,
  scene      text not null,
  targets    jsonb not null,
  note       text,
  updated_at timestamptz not null default now(),
  unique (type_key, scene)
);
insert into notice_mention_rules(type_key, scene, targets, note) values
  ('attendance_fix', 'open', '[{"kind":"store_role","roles":["SHAIN","TENCHO"]},{"kind":"store_team_leader"}]', '対象店舗の社員全員（店長を含む）＋その店舗の担当チーム長'),
  ('onboarding',     'open', '[{"kind":"role","roles":["HQ","CEO"]},{"kind":"role","roles":["TEAM"]}]', '本部全員（社長を含む）＋チーム長全員'),
  ('retirement',     'open', '[{"kind":"role","roles":["HQ","CEO"]},{"kind":"role","roles":["TEAM"]}]', '本部全員（社長を含む）＋チーム長全員'),
  ('wage_change',    'open', '[{"kind":"task_assignee"}]', '本部確認の段階は、既存の担当者ルール（本部タスクの担当）'),
  ('wage_change',    'stage:president', '[{"kind":"role","roles":["CEO"]}]', '社長本人（本部確認が済んで、最終承認を依頼するとき）')
on conflict (type_key, scene) do nothing;

-- ============ 3. 案件の控え（種類×元の記録ごとに 1 行。親メッセージ・詳細カード・操作カードの控えと、進捗） ============
create table if not exists notice_cases (
  id             uuid primary key default gen_random_uuid(),
  type_key       text not null references notice_types(type_key),
  ref_table      text not null,
  ref_id         text not null,
  subject_user   uuid,
  store_id       uuid,
  subject_date   date,
  status_code    text not null default 'todo' check (status_code in ('todo', 'waiting', 'doing', 'done', 'alert')),   -- ⚪未対応／🟡確認待ち／🔵対応中／🟢完了／🔴要対応
  status_label   text,                                    -- 段階の言葉（本部確認待ち・社長承認待ち など）
  assignees      uuid[] not null default '{}',            -- いま対応すべき人（メンション先。承認権限とは別）
  external_state text not null default 'none' check (external_state in ('none', 'detected')),      -- 外部（スマレジなど）で変更を検知したか
  review_state   text not null default 'none' check (review_state in ('none', 'confirmed')),      -- 本部が確認したか（検知しただけでは完了にしない）
  slack_refs     jsonb not null default '{}'::jsonb,      -- {"<channel_key>": {"parent": 台帳の番号, "detail": …, "control": …}}
  format_version integer not null default 2,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  closed_at      timestamptz,
  unique (type_key, ref_table, ref_id)
);
create index if not exists notice_cases_open_idx on notice_cases (type_key, status_code) where closed_at is null;

-- ============ 4. 未連携の確認タスクの控え（未連携の人ごとに 1 件。開いているあいだは増やさない） ============
create table if not exists notice_unlinked_tasks (
  user_id    uuid primary key,
  task_id    uuid,
  types      text[] not null default '{}',     -- 届いていない通知の種類
  urgent     boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at  timestamptz
);

alter table notice_types enable row level security;
alter table notice_mention_rules enable row level security;
alter table notice_cases enable row level security;
alter table notice_unlinked_tasks enable row level security;
-- 画面からは読むだけ（書くのは関数だけ）
drop policy if exists notice_types_read on notice_types;
create policy notice_types_read on notice_types for select using (hq_can_manage());
drop policy if exists notice_mention_rules_read on notice_mention_rules;
create policy notice_mention_rules_read on notice_mention_rules for select using (hq_can_manage());
drop policy if exists notice_cases_read on notice_cases;
create policy notice_cases_read on notice_cases for select using (hq_can_manage());
drop policy if exists notice_unlinked_tasks_read on notice_unlinked_tasks;
create policy notice_unlinked_tasks_read on notice_unlinked_tasks for select using (hq_can_manage());

-- 設定: 未連携の確認タスクの担当（主担当 1 人・予備）と、通知の対象から外すアカウント（テスト用・連携用）。
--   ★ 担当者は SQL に書かない（公開リポジトリのため）。切り替えのときに notice_settings_set で入れる。入っていないあいだ、確認タスクは作らない（勝手に別の人へ割り当てない）
insert into app_settings(key, value) values ('notice', '{"unlinked_task_owner": null, "unlinked_task_backup": [], "exclude_user_ids": []}'::jsonb) on conflict (key) do nothing;
insert into app_settings(key, value) values ('slack_policy', '{"hide_amount_channels": []}'::jsonb) on conflict (key) do nothing;

create or replace function notice_settings_set(p_owner uuid, p_backup uuid[] default '{}', p_exclude uuid[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not (onboarding_is_service() or coalesce((select is_master from users where id = auth.uid() and is_active), false)) then raise exception '権限がありません（マスターのみ）'; end if;
  if p_owner is not null and not exists (select 1 from users where id = p_owner and is_active) then raise exception '主担当のアカウントが見つからないか、無効です'; end if;
  if exists (select 1 from unnest(coalesce(p_backup, '{}')) b where not exists (select 1 from users u where u.id = b and u.is_active)) then raise exception '予備担当に、見つからないか無効のアカウントがあります'; end if;
  select value into v from app_settings where key = 'notice';
  v := coalesce(v, '{}'::jsonb) || jsonb_build_object('unlinked_task_owner', p_owner, 'unlinked_task_backup', to_jsonb(coalesce(p_backup, '{}')))
       || case when p_exclude is not null then jsonb_build_object('exclude_user_ids', to_jsonb(p_exclude)) else '{}'::jsonb end;
  update app_settings set value = v where key = 'notice';
  return v;
end $$;

-- ============ 5. メンション先の解決（ここ 1 か所） ============
--   返すもの: targets＝メンションする人（Slack のユーザー ID つき）／unlinked＝対象だが Slack と紐付いていない人／rule_found
--   対象に 1 人もメンションできなくても、ほかの人には広げない（targets が空のまま返る）
create or replace function notice_mention_targets(p_type text, p_scene text, p_store uuid default null, p_task_assignees uuid[] default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r notice_mention_rules%rowtype; t jsonb; v_ids uuid[] := '{}'; v_ex uuid[];
begin
  if not (hq_can_manage() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  select * into r from notice_mention_rules where type_key = p_type and scene = p_scene;
  if r.id is null then return jsonb_build_object('rule_found', false, 'targets', '[]'::jsonb, 'unlinked', '[]'::jsonb); end if;
  select coalesce(array_agg(x::uuid), '{}') into v_ex from jsonb_array_elements_text(coalesce((select value -> 'exclude_user_ids' from app_settings where key = 'notice'), '[]'::jsonb)) x;
  for t in select * from jsonb_array_elements(r.targets) loop
    if t ->> 'kind' = 'role' then
      v_ids := v_ids || coalesce((select array_agg(u.id) from users u where u.role in (select jsonb_array_elements_text(t -> 'roles'))), '{}');
    elsif t ->> 'kind' = 'store_role' and p_store is not null then
      v_ids := v_ids || coalesce((select array_agg(u.id) from users u join user_stores us on us.user_id = u.id where us.store_id = p_store and u.role in (select jsonb_array_elements_text(t -> 'roles'))), '{}');
    elsif t ->> 'kind' = 'store_team_leader' and p_store is not null then
      v_ids := v_ids || coalesce((select array_agg(u.id) from users u join team_stores ts on ts.team_id = u.team_id where ts.store_id = p_store and u.role = 'TEAM'), '{}');
    elsif t ->> 'kind' = 'user' then
      v_ids := v_ids || (t ->> 'user_id')::uuid;
    elsif t ->> 'kind' = 'task_assignee' then
      v_ids := v_ids || coalesce(p_task_assignees, '{}');
    end if;
  end loop;
  return (
    with c as (   -- 重複を 1 人に・退職/無効を除く・通知から外す設定の人を除く
      select distinct u.id, u.role, k.slack_user_id from users u left join user_slack k on k.user_id = u.id
       where u.id = any(v_ids) and u.is_active and u.deactivated_at is null and not (u.id = any(v_ex)))
    select jsonb_build_object('rule_found', true,
      'targets', coalesce((select jsonb_agg(jsonb_build_object('user_id', c.id, 'slack_user_id', c.slack_user_id) order by c.id) from c where c.slack_user_id is not null), '[]'::jsonb),
      'unlinked', coalesce((select jsonb_agg(c.id order by c.id) from c where c.slack_user_id is null), '[]'::jsonb)));
end $$;

-- ============ 6. 未連携の確認タスク（決めた主担当に 1 人 1 件。担当が決まっていなければ作らない） ============
--   紐付けが済んだ人のタスクは、呼ばれたときに自動で完了にする
create or replace function notice_unlinked_task_sync(p_users uuid[], p_type text, p_urgent boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_cfg jsonb; v_owner uuid; v_backup uuid[]; u uuid; rec notice_unlinked_tasks%rowtype; v_task uuid; v_name text; v_label text; v_created int := 0; v_updated int := 0; v_closed int := 0; q record;
begin
  if not (hq_can_manage() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  -- 紐付けが済んだ人・退職した人のタスクを閉じる
  for q in select t.user_id, t.task_id from notice_unlinked_tasks t where t.closed_at is null
            and (exists (select 1 from user_slack k where k.user_id = t.user_id) or not exists (select 1 from users x where x.id = t.user_id and x.is_active)) loop
    update hq_task_steps set completed_at = now() where task_id = q.task_id and completed_at is null;
    insert into hq_task_activity(task_id, actor_id, kind, detail) values (q.task_id, null, 'step_complete', 'Slack の紐付けが済んだ（または退職・無効になった）ため自動で完了');
    update notice_unlinked_tasks set closed_at = now(), updated_at = now() where user_id = q.user_id;
    v_closed := v_closed + 1;
  end loop;
  select value into v_cfg from app_settings where key = 'notice';
  v_owner := nullif(v_cfg ->> 'unlinked_task_owner', '')::uuid;
  if v_owner is null or not exists (select 1 from users where id = v_owner and is_active) then
    -- 担当が決まっていない・無効: 勝手に別の人へ割り当てない。作らずに知らせる
    return jsonb_build_object('ok', false, 'reason', 'owner_unset', 'created', 0, 'closed', v_closed, 'pending_users', coalesce(cardinality(p_users), 0));
  end if;
  select coalesce(array_agg(x::uuid), '{}') into v_backup from jsonb_array_elements_text(coalesce(v_cfg -> 'unlinked_task_backup', '[]'::jsonb)) x;
  select label into v_label from notice_types where type_key = p_type;
  foreach u in array coalesce(p_users, '{}') loop
    if exists (select 1 from user_slack k where k.user_id = u) or not exists (select 1 from users x where x.id = u and x.is_active) then continue; end if;
    select * into rec from notice_unlinked_tasks where user_id = u;
    if rec.user_id is not null and rec.closed_at is null then
      if not (p_type = any(rec.types)) or (p_urgent and not rec.urgent) then
        update notice_unlinked_tasks set types = case when p_type = any(types) then types else types || p_type end, urgent = urgent or p_urgent, updated_at = now() where user_id = u;
        insert into hq_task_activity(task_id, actor_id, kind, detail) values (rec.task_id, null, 'comment', '届いていない通知が増えました: ' || coalesce(v_label, p_type) || case when p_urgent then '（だれにも通知できていません・至急）' else '' end);
        v_updated := v_updated + 1;
      end if;
      continue;
    end if;
    select name into v_name from users where id = u;
    insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by)
    values (case when p_urgent then '【至急】' else '' end || 'Slack 未連携の確認（' || coalesce(v_name, '—') || 'さん）',
            coalesce((select c.name from user_stores us join stores st on st.id = us.store_id join corporations c on c.id = st.corporation_id where us.user_id = u order by us.is_primary desc, st.sort_order limit 1), 'トーホー'), 'once', current_date, current_date + 3, '',
            coalesce(v_name, '—') || 'さんが Slack と紐付いていないため、通知（' || coalesce(v_label, p_type) || '）を届けられていません。' || E'\n' ||
            'Slack への参加・紐付けを本人に案内してください（従業員ページの「Slack連携」から招待できます）。' || E'\n' ||
            'https://mirai-oss.github.io/nippo/?page=admin&u=' || u || E'\n' || '※ 紐付けが済むと、このタスクは自動で完了になります。通知の内容（金額など）はここには書きません。',
            'members', v_owner)
    returning id into v_task;
    insert into hq_task_steps(task_id, title, assignee_id, assignee_ids, sort_order, kind, due_date)
    values (v_task, '本人に Slack の参加・紐付けを案内する', v_owner, array[v_owner] || v_backup, 10, 'step', current_date + 3);
    insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, v_owner, 'create', 'Slack 未連携のため自動作成（' || coalesce(v_label, p_type) || '）');
    insert into notice_unlinked_tasks(user_id, task_id, types, urgent) values (u, v_task, array[p_type], coalesce(p_urgent, false))
    on conflict (user_id) do update set task_id = excluded.task_id, types = excluded.types, urgent = excluded.urgent, created_at = now(), updated_at = now(), closed_at = null;
    v_created := v_created + 1;
  end loop;
  return jsonb_build_object('ok', true, 'created', v_created, 'updated', v_updated, 'closed', v_closed);
end $$;

-- ============ 7. 案件の控えを作る・進める（送信の入口の Edge Function が呼ぶ） ============
create or replace function notice_case_upsert(p_type text, p_ref_table text, p_ref_id text, p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c notice_cases%rowtype; v_done boolean;
begin
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  insert into notice_cases(type_key, ref_table, ref_id) values (p_type, p_ref_table, p_ref_id) on conflict (type_key, ref_table, ref_id) do nothing;
  select * into c from notice_cases where type_key = p_type and ref_table = p_ref_table and ref_id = p_ref_id for update;
  -- 外部で検知しただけでは完了にしない: 完了（done）にできるのは、外部の検知が無いか、本部の確認が済んでいるときだけ
  v_done := coalesce(p_patch ->> 'status_code', c.status_code) = 'done';
  if v_done and coalesce(p_patch ->> 'external_state', c.external_state) = 'detected' and coalesce(p_patch ->> 'review_state', c.review_state) <> 'confirmed' then
    raise exception '外部での変更を検知しただけでは完了にできません（本部の確認が必要です）';
  end if;
  update notice_cases set
    subject_user = coalesce(nullif(p_patch ->> 'subject_user', '')::uuid, subject_user), store_id = coalesce(nullif(p_patch ->> 'store_id', '')::uuid, store_id),
    subject_date = coalesce(nullif(p_patch ->> 'subject_date', '')::date, subject_date),
    status_code = coalesce(p_patch ->> 'status_code', status_code), status_label = case when p_patch ? 'status_label' then p_patch ->> 'status_label' else status_label end,
    assignees = case when p_patch ? 'assignees' then coalesce((select array_agg(x::uuid) from jsonb_array_elements_text(p_patch -> 'assignees') x), '{}') else assignees end,
    external_state = coalesce(p_patch ->> 'external_state', external_state), review_state = coalesce(p_patch ->> 'review_state', review_state),
    slack_refs = slack_refs || coalesce(p_patch -> 'slack_refs', '{}'::jsonb),
    closed_at = case when v_done then coalesce(closed_at, now()) else null end, updated_at = now()
  where id = c.id returning * into c;
  return to_jsonb(c);
end $$;

revoke all on function notice_settings_set(uuid, uuid[], uuid[]), notice_mention_targets(text, text, uuid, uuid[]), notice_unlinked_task_sync(uuid[], text, boolean), notice_case_upsert(text, text, text, jsonb) from public, anon, authenticated;
grant execute on function notice_settings_set(uuid, uuid[], uuid[]), notice_mention_targets(text, text, uuid, uuid[]), notice_unlinked_task_sync(uuid[], text, boolean) to authenticated, service_role;
grant execute on function notice_case_upsert(text, text, text, jsonb) to service_role;
