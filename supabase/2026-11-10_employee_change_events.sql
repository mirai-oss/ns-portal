-- 従業員情報の変更: 共通の「変更イベント → 影響判定 → 同期・対応の追跡」（ステップ 1・2・2026-11-10）
--   設計: docs/設計書_従業員情報変更の連動_2026-11-10.md
--   ★ 本番未適用（開発・テストのみ承認。適用は別途承認）。戻し方: 2026-11-10_employee_change_events_rollback.sql
--
--   ステップ 1: 重要項目の変更を必ず 1 行残す（本人の直接編集・本部の直接編集・申請の承認・システム処理のどれでも）。既存の画面・RPC は変えない（記録用トリガーを足すだけ）
--   ステップ 2: 住所・最寄り駅・所属店舗・雇用形態が変わったら「交通費の再確認」を 1 人 1 件だけ起動する
--               ・旧交通費（承認額・設定・スマレジ）は触らない。本部が再承認し、適用開始日を決めて設定したときに初めて変わる（既存の流れ）
--               ・本部への Slack 通知は app_settings.employee_change.notify_enabled=true のときだけ（既定 false＝OFF）
--   重複防止: ①同じ取引で同じ人×同じ項目グループは 1 イベントにまとめる ②所属店舗の「全削除→入れ直し」は 2 分以内なら 1 イベントにまとめ、結果が同じなら「変更なし」
--             ③未完了の影響は 1 人×種類ごとに 1 件（部分ユニーク索引）。後から来たイベントは既存の影響にひも付けるだけ
--   閲覧権限: 表は マスター・本部（is_profile_approver）だけ。本部系（hq_can_manage）には RPC で一覧を返し、機微な項目（住所・口座・賃金・連絡先）の値は伏せる
--   安全: 記録に失敗しても元の保存は止めない（失敗は employee_change_errors に残す）

-- ============ 1. ルール（項目グループごとの正本・同期先・起動する影響） ============
create table if not exists employee_change_rules (
  field_group text primary key,
  label text not null,
  source_of_truth text not null check (source_of_truth in ('hub','smaregi','document')),   -- 正本: hub=管理システム／smaregi=スマレジ／document=書面
  external_targets text[] not null default '{}',     -- 写しを持つ外部（同期先）
  sensitive boolean not null default false,          -- true: 変更前後の値は マスター・本部だけ
  effects text[] not null default '{}',              -- 変わったら起動する影響（実装済みは commute_recheck）
  planned_effects text[] not null default '{}',      -- 今後つなぐ予定（記録だけ・まだ起動しない）
  note text,
  updated_at timestamptz not null default now()
);
insert into employee_change_rules(field_group, label, source_of_truth, external_targets, sensitive, effects, planned_effects, note) values
  ('name',              '氏名・フリガナ',           'hub', '{smaregi_api}',          false, '{}',                '{smaregi_name_push,bank_holder_check}', 'スマレジへは初回登録時のみ反映（現状）'),
  ('personal',          '生年月日・性別',           'hub', '{smaregi_api}',          true,  '{}',                '{}', null),
  ('address',           '住所',                     'hub', '{smaregi_api}',          true,  '{commute_recheck}', '{smaregi_profile_push}', '住所が変わったら通勤経路の再確認は必須（駅が変わるとは限らないので自動では決めない）'),
  ('nearest_station',   '最寄り駅・通勤手段',       'hub', '{}',                     false, '{commute_recheck}', '{}', null),
  ('contact',           '電話・緊急連絡先・連絡用メール', 'hub', '{smaregi_api}',    true,  '{}',                '{smaregi_profile_push}', null),
  ('stores',            '所属店舗・主店舗',         'hub', '{smaregi_api}',          false, '{commute_recheck}', '{smaregi_affiliation}', '勤務先（通勤先）の店舗が変わったときだけ交通費の再確認'),
  ('role',              '役職・権限',               'hub', '{}',                     false, '{}',                '{}', 'スマレジの権限は別管理（連動しない）'),
  ('employment_class',  '雇用形態（アルバイト／社員）', 'hub', '{smaregi_ui}',       false, '{commute_recheck}', '{smaregi_class,post_join_rules}', '交通費の月額上限の標準が変わる（アルバイト 6,000 円／社員なし）'),
  ('employment_status', '在籍（入社日・退職日・有効／無効）', 'hub', '{smaregi_api}', false, '{}',               '{offboarding_cleanup}', '退職・移籍の申請と自動反映は hr_change_requests が担当'),
  ('wage',              '賃金（時給・日給・月給）', 'hub', '{smaregi_api}',          true,  '{}',                '{wage_approval}', 'スマレジ同期は既存（employee_wage_settings.sync_status）'),
  ('bank_account',      '銀行口座・支払方法',       'hub', '{payroll_csv}',          true,  '{}',                '{bank_effective_payday}', 'スマレジには持たせない')
on conflict (field_group) do nothing;

-- ============ 2. 変更イベント（追記。値の修正は「まとめ」のときだけ） ============
create table if not exists employee_change_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  field_group text not null references employee_change_rules(field_group),
  source text not null check (source in ('self_direct','hq_direct','request','system')),   -- 本人が直接／本部が直接／申請の承認／システム処理
  source_table text not null,
  op text not null check (op in ('insert','update','delete')),
  changed_keys text[] not null default '{}',
  before jsonb, after jsonb,                    -- 変更前後（機微な項目は閲覧制限）
  changed_by uuid,                              -- 実際に書き換えた人（auth.uid()。システム処理は null）
  requested_by uuid, requested_at timestamptz,  -- 申請者・申請日（申請経由のとき）
  approved_by uuid, approved_at timestamptz,    -- 承認者・承認日
  request_table text, request_id uuid,
  change_date date,                             -- 事実が起きた日（引越日・改姓日など）。分からなければ null（後から本部が入力）
  effective_date date,                          -- 適用開始日（元データにある場合＝賃金など。交通費は影響側で決める）
  status text not null default 'recorded' check (status in ('recorded','no_change')),
  txid bigint not null default txid_current(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists employee_change_events_txn on employee_change_events(user_id, field_group, txid);
create index if not exists employee_change_events_user on employee_change_events(user_id, created_at desc);

-- ============ 3. 影響（変更から起動された対応。1 人×種類で未完了は 1 件） ============
create table if not exists employee_change_effects (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  effect_key text not null check (effect_key in ('commute_recheck')),
  status text not null default 'pending' check (status in ('pending','in_progress','done','not_needed','cancelled','error')),
  reasons text[] not null default '{}',         -- 何が変わったか（項目名だけ。値は入れない）
  change_date date,                             -- 変更日（イベントから。複数あれば最も早い日）
  retroactive boolean not null default false,   -- 変更日が締め済みの月（前月以前）＝過去にさかのぼる変更
  suggested_effective_date date,                -- 適用開始の目安（月単位。決めるのは本部）
  snapshot jsonb,                               -- 起動時点の旧状態（旧承認額・旧経路・旧設定）＝あとから「何から変わったか」を追える
  result jsonb,                                 -- 結果（新承認額・変わったか・設定と同期の状態）
  hq_task_id uuid,
  notified_at timestamptz, notification_id uuid,
  resolved_by uuid, resolved_at timestamptz, resolve_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists employee_change_effects_open on employee_change_effects(user_id, effect_key) where status in ('pending','in_progress');
create index if not exists employee_change_effects_user on employee_change_effects(user_id, created_at desc);
create table if not exists employee_change_effect_events (
  effect_id uuid not null references employee_change_effects(id) on delete cascade,
  event_id uuid not null references employee_change_events(id) on delete cascade,
  primary key (effect_id, event_id)
);
create table if not exists employee_change_errors (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(), source_table text, op text, user_id uuid, message text
);

alter table employee_commute add column if not exists recheck_required_at timestamptz;
alter table employee_commute add column if not exists recheck_effect_id uuid;
alter table employee_commute add column if not exists recheck_reason text;

alter table employee_change_rules enable row level security;
alter table employee_change_events enable row level security;
alter table employee_change_effects enable row level security;
alter table employee_change_effect_events enable row level security;
alter table employee_change_errors enable row level security;
drop policy if exists employee_change_rules_read on employee_change_rules;
create policy employee_change_rules_read on employee_change_rules for select using (hq_can_manage());
drop policy if exists employee_change_events_read on employee_change_events;
create policy employee_change_events_read on employee_change_events for select using (is_profile_approver());   -- 値を含むため マスター・本部だけ（他は RPC の一覧＝値を伏せる）
drop policy if exists employee_change_effects_read on employee_change_effects;
create policy employee_change_effects_read on employee_change_effects for select using (hq_can_manage());
drop policy if exists employee_change_effect_events_read on employee_change_effect_events;
create policy employee_change_effect_events_read on employee_change_effect_events for select using (hq_can_manage());
drop policy if exists employee_change_errors_read on employee_change_errors;
create policy employee_change_errors_read on employee_change_errors for select using (is_profile_approver());
-- 書き込みのポリシーは作らない（下の SECURITY DEFINER 関数だけが書く）

insert into app_settings(key, value) values ('employee_change', '{"notify_enabled": false}'::jsonb) on conflict (key) do nothing;

-- ============ 4. 補助関数 ============
-- 過去日付・適用開始の目安（給与は末日締め・翌月 15 日払い。交通費は月単位）
--   変更日が今月以降 → その月の 1 日から／前月以前 → 締め済みなので「今月 1 日から」を目安にし、さかのぼり分は自動では直さない（精算するかは本部判断）
create or replace function employee_change_effective_hint(p_change_date date, p_today date default current_date)
returns jsonb language sql immutable as $$
  select case
    when p_change_date is null then jsonb_build_object('retroactive', false, 'suggested_effective_date', null, 'note', '変更日が未入力です（本部が入力すると目安が出ます）')
    when p_change_date >= date_trunc('month', p_today)::date then jsonb_build_object('retroactive', false, 'suggested_effective_date', date_trunc('month', p_change_date)::date, 'note', null)
    else jsonb_build_object('retroactive', true, 'suggested_effective_date', date_trunc('month', p_today)::date,
           'note', '変更日が締め済みの月です。' || to_char(p_change_date, 'YYYY/MM') || '〜前月分の差額は自動では直しません（精算するかは本部が判断）')
  end
$$;

-- 所属店舗の状態（店舗 id の並びと主店舗）
create or replace function employee_change_stores_state(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'stores', coalesce((select jsonb_agg(us.store_id order by us.store_id::text) from user_stores us where us.user_id = p_user), '[]'::jsonb),
    'primary', (select us.store_id from user_stores us where us.user_id = p_user and us.is_primary order by us.store_id limit 1))
$$;
-- 通勤先の店舗（経路検索 commute-route と同じ決め方: 並び順が先頭の店舗）
create or replace function employee_change_work_store(p_store_ids jsonb)
returns uuid language sql stable security definer set search_path = public as $$
  select s.id from stores s where s.id in (select (x #>> '{}')::uuid from jsonb_array_elements(coalesce(p_store_ids, '[]'::jsonb)) x) order by coalesce(s.sort_order, 0), s.id limit 1
$$;

-- ============ 5. 影響の起動（交通費の再確認） ============
create or replace function employee_change_dispatch(p_event uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare e employee_change_events%rowtype; r employee_change_rules%rowtype; v_effect uuid; v_reason text; v_hint jsonb; v_snap jsonb; v_need boolean := true; v_notify boolean;
begin
  select * into e from employee_change_events where id = p_event;
  if e.id is null or e.status <> 'recorded' then return null; end if;
  select * into r from employee_change_rules where field_group = e.field_group;
  if not ('commute_recheck' = any(r.effects)) then return null; end if;
  if not exists (select 1 from users u where u.id = e.user_id and u.is_active) then return null; end if;   -- 無効（退職済み）の人は対象外
  -- 所属店舗: 通勤先（先頭の店舗）が変わったときだけ。全部外れた（空）ときは起動しない
  if e.field_group = 'stores' then
    if jsonb_array_length(coalesce(e.after -> 'stores', '[]'::jsonb)) = 0 then return null; end if;
    v_need := employee_change_work_store(e.before -> 'stores') is distinct from employee_change_work_store(e.after -> 'stores');
  end if;
  if not v_need then return null; end if;
  v_reason := r.label;
  -- 既に未完了の再確認があれば、それにひも付けるだけ（同じ変更から申請・通知・ジョブを二重に出さない）
  select id into v_effect from employee_change_effects where user_id = e.user_id and effect_key = 'commute_recheck' and status in ('pending','in_progress') for update;
  if v_effect is null then
    v_hint := employee_change_effective_hint(e.change_date);
    select jsonb_build_object('has_commute_record', true, 'judgement', c.judgement, 'approved_fare', c.approved_fare, 'approved_at', c.approved_at, 'home_station', c.home_station, 'route_text', c.route_text,
             'pay_policy', c.pay_policy, 'monthly_cap_override', c.monthly_cap_override, 'work_store_id', c.search_result ->> 'store_id',
             'latest_setting', (select jsonb_build_object('id', s.id, 'pay_type', s.pay_type, 'amount', s.amount, 'cap_amount', s.cap_amount, 'effective_date', s.effective_date, 'sync_status', s.sync_status)
                                  from employee_commute_settings s where s.user_id = e.user_id order by s.created_at desc limit 1))
      into v_snap from employee_commute c where c.user_id = e.user_id;
    begin
      insert into employee_change_effects(user_id, effect_key, reasons, change_date, retroactive, suggested_effective_date, snapshot)
      values (e.user_id, 'commute_recheck', array[v_reason], e.change_date, coalesce((v_hint ->> 'retroactive')::boolean, false), (v_hint ->> 'suggested_effective_date')::date,
              coalesce(v_snap, jsonb_build_object('has_commute_record', false)))
      returning id into v_effect;
    exception when unique_violation then
      select id into v_effect from employee_change_effects where user_id = e.user_id and effect_key = 'commute_recheck' and status in ('pending','in_progress');
    end;
    -- 旧交通費（承認額・設定）は変えない。「再確認が必要」の印だけ付ける
    update employee_commute set recheck_required_at = coalesce(recheck_required_at, now()), recheck_effect_id = v_effect, recheck_reason = v_reason, updated_at = now() where user_id = e.user_id;
    -- 本部への通知（既定 OFF）。pg_net は取引の確定後に送られる。通知側（EF）も notified_at で二重送信を防ぐ
    select coalesce((value ->> 'notify_enabled')::boolean, false) into v_notify from app_settings where key = 'employee_change';
    if coalesce(v_notify, false) then perform employee_change_notify(v_effect); end if;
  else
    update employee_change_effects set reasons = (select array_agg(distinct x) from unnest(reasons || v_reason) x),
           change_date = least(change_date, e.change_date), updated_at = now() where id = v_effect;
  end if;
  insert into employee_change_effect_events(effect_id, event_id) values (v_effect, e.id) on conflict do nothing;
  return v_effect;
end $$;

-- 通知の発火（EF onboarding-notify op=change_effect を呼ぶだけ。フラグ OFF のあいだは呼ばれない）
create or replace function employee_change_notify(p_effect uuid)
returns void language plpgsql security definer set search_path = public, net, extensions as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/onboarding-notify';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'employee_change_notify: notify_slack_secret 未設定'; return; end if;
  perform net.http_post(url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'change_effect', 'effect_id', p_effect), timeout_milliseconds := 60000);
end $$;

-- 「変更なし」になったイベントだけから出来た、未通知・未着手の影響は取り下げる
create or replace function employee_change_retract(p_event uuid)
returns void language plpgsql security definer set search_path = public as $$
declare f record;
begin
  for f in select ef.id from employee_change_effects ef join employee_change_effect_events l on l.effect_id = ef.id
            where l.event_id = p_event and ef.status = 'pending' and ef.notified_at is null
              and not exists (select 1 from employee_change_effect_events l2 join employee_change_events e2 on e2.id = l2.event_id where l2.effect_id = ef.id and l2.event_id <> p_event and e2.status = 'recorded') loop
    update employee_change_effects set status = 'cancelled', resolve_note = '変更が取り消された（結果として変更なし）', resolved_at = now(), updated_at = now() where id = f.id;
    update employee_commute set recheck_required_at = null, recheck_effect_id = null, recheck_reason = null where recheck_effect_id = f.id;
  end loop;
end $$;

-- ============ 6. 記録の本体 ============
create or replace function employee_change_record(p_user uuid, p_group text, p_table text, p_op text, p_before jsonb, p_after jsonb, p_effective date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_before jsonb; v_after jsonb; v_status text; v_old_status text; v_src text; v_uid uuid := auth.uid(); q profile_change_requests%rowtype; v_keys text[];
begin
  if p_user is null then return null; end if;
  if coalesce(p_before, '{}'::jsonb) = coalesce(p_after, '{}'::jsonb) then return null; end if;
  v_src := case when v_uid is null then 'system' when v_uid = p_user then 'self_direct' else 'hq_direct' end;
  -- まとめ: 同じ取引の同じ人×同じグループ。所属店舗だけは「全削除→入れ直し」（別々の取引）を 2 分以内なら同じ操作として扱う
  select id, before, status into v_id, v_before, v_old_status from employee_change_events
   where user_id = p_user and field_group = p_group
     and (txid = txid_current() or (p_group = 'stores' and created_at > now() - interval '2 minutes' and changed_by is not distinct from v_uid))
   order by created_at desc limit 1 for update;
  if v_id is not null then
    if p_group = 'stores' then v_after := p_after;
    else v_before := coalesce(p_before, '{}'::jsonb) || coalesce(v_before, '{}'::jsonb);   -- 最初の「変更前」を優先
         select coalesce(after, '{}'::jsonb) || coalesce(p_after, '{}'::jsonb) into v_after from employee_change_events where id = v_id;
    end if;
    select array_agg(k) into v_keys from (select k from jsonb_object_keys(coalesce(v_before, '{}'::jsonb) || coalesce(v_after, '{}'::jsonb)) k where (v_before -> k) is distinct from (v_after -> k)) x;
    v_status := case when coalesce(v_before, '{}'::jsonb) = coalesce(v_after, '{}'::jsonb) then 'no_change' else 'recorded' end;
    update employee_change_events set before = v_before, after = v_after, changed_keys = coalesce(v_keys, '{}'), status = v_status, effective_date = coalesce(p_effective, effective_date), updated_at = clock_timestamp() where id = v_id;
    if v_status = 'no_change' then perform employee_change_retract(v_id); return v_id; end if;
  else
    select array_agg(k) into v_keys from (select k from jsonb_object_keys(coalesce(p_before, '{}'::jsonb) || coalesce(p_after, '{}'::jsonb)) k where (p_before -> k) is distinct from (p_after -> k)) x;
    insert into employee_change_events(user_id, field_group, source, source_table, op, changed_keys, before, after, changed_by, effective_date)
    values (p_user, p_group, v_src, p_table, p_op, coalesce(v_keys, '{}'), p_before, p_after, v_uid, p_effective) returning id into v_id;
    -- 申請の承認から来た変更なら、申請者・承認者をひも付ける（承認の RPC が同じ取引で申請行を先に更新していた場合）
    select * into q from profile_change_requests where user_id = p_user and status = 'approved' and reviewed_at = now()
       and employee_change_group_of_request(field) = p_group order by requested_at desc limit 1;
    if q.id is not null then
      update employee_change_events set source = 'request', request_table = 'profile_change_requests', request_id = q.id,
             requested_by = q.requested_by, requested_at = q.requested_at, approved_by = q.reviewed_by, approved_at = q.reviewed_at where id = v_id;
    end if;
  end if;
  perform employee_change_dispatch(v_id);
  return v_id;
end $$;

create or replace function employee_change_group_of_request(p_field text)
returns text language sql immutable as $$
  select case p_field when 'name' then 'name' when 'kana' then 'name' when 'phone' then 'contact' when 'contact_email' then 'contact' when 'address' then 'address' when 'bank_account' then 'bank_account' else null end
$$;

-- 記録に失敗しても元の保存は止めない（失敗は表に残す）
create or replace function employee_change_log_error(p_table text, p_op text, p_user uuid, p_message text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into employee_change_errors(source_table, op, user_id, message) values (p_table, p_op, p_user, left(p_message, 500));
exception when others then raise warning 'employee_change: %', p_message;
end $$;

-- ============ 7. 記録用トリガー（既存の画面・RPC の動きは変えない） ============
create or replace function employee_change_trg_users() returns trigger language plpgsql security definer set search_path = public as $$
declare b jsonb; a jsonb;
begin
  begin
    if new.name is distinct from old.name then perform employee_change_record(new.id, 'name', 'users', 'update', jsonb_build_object('name', old.name), jsonb_build_object('name', new.name)); end if;
    b := jsonb_strip_nulls(jsonb_build_object('role', old.role, 'is_master', old.is_master, 'concurrent_role', old.concurrent_role, 'team_id', old.team_id));
    a := jsonb_strip_nulls(jsonb_build_object('role', new.role, 'is_master', new.is_master, 'concurrent_role', new.concurrent_role, 'team_id', new.team_id));
    if a is distinct from b then perform employee_change_record(new.id, 'role', 'users', 'update', b, a); end if;
    if post_join_class(old.role) is distinct from post_join_class(new.role) then
      perform employee_change_record(new.id, 'employment_class', 'users', 'update', jsonb_build_object('class', post_join_class(old.role)), jsonb_build_object('class', post_join_class(new.role)));
    end if;
    if new.is_active is distinct from old.is_active or new.deactivated_at is distinct from old.deactivated_at then
      perform employee_change_record(new.id, 'employment_status', 'users', 'update', jsonb_strip_nulls(jsonb_build_object('is_active', old.is_active, 'deactivated_at', old.deactivated_at)), jsonb_strip_nulls(jsonb_build_object('is_active', new.is_active, 'deactivated_at', new.deactivated_at)));
    end if;
  exception when others then perform employee_change_log_error('users', 'update', new.id, sqlerrm);
  end;
  return null;
end $$;

create or replace function employee_change_trg_profiles() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    -- 空文字と null は同じ扱い（フォームの保存で差分が出ないように）
    if nullif(trim(coalesce(new.name_kana, '')), '') is distinct from nullif(trim(coalesce(old.name_kana, '')), '') then
      perform employee_change_record(new.user_id, 'name', 'employee_profiles', 'update', jsonb_build_object('name_kana', old.name_kana), jsonb_build_object('name_kana', new.name_kana)); end if;
    if new.birth_date is distinct from old.birth_date or new.gender is distinct from old.gender then
      perform employee_change_record(new.user_id, 'personal', 'employee_profiles', 'update', jsonb_strip_nulls(jsonb_build_object('birth_date', old.birth_date, 'gender', old.gender)), jsonb_strip_nulls(jsonb_build_object('birth_date', new.birth_date, 'gender', new.gender))); end if;
    if nullif(trim(coalesce(new.postal_code, '')), '') is distinct from nullif(trim(coalesce(old.postal_code, '')), '') or nullif(trim(coalesce(new.address, '')), '') is distinct from nullif(trim(coalesce(old.address, '')), '') then
      perform employee_change_record(new.user_id, 'address', 'employee_profiles', 'update', jsonb_strip_nulls(jsonb_build_object('postal_code', nullif(trim(coalesce(old.postal_code, '')), ''), 'address', nullif(trim(coalesce(old.address, '')), ''))),
                                     jsonb_strip_nulls(jsonb_build_object('postal_code', nullif(trim(coalesce(new.postal_code, '')), ''), 'address', nullif(trim(coalesce(new.address, '')), '')))); end if;
    if nullif(trim(coalesce(new.extra ->> '最寄り駅', '')), '') is distinct from nullif(trim(coalesce(old.extra ->> '最寄り駅', '')), '') or nullif(trim(coalesce(new.extra ->> '通勤手段', '')), '') is distinct from nullif(trim(coalesce(old.extra ->> '通勤手段', '')), '') then
      perform employee_change_record(new.user_id, 'nearest_station', 'employee_profiles', 'update', jsonb_strip_nulls(jsonb_build_object('最寄り駅', nullif(trim(coalesce(old.extra ->> '最寄り駅', '')), ''), '通勤手段', nullif(trim(coalesce(old.extra ->> '通勤手段', '')), ''))),
                                     jsonb_strip_nulls(jsonb_build_object('最寄り駅', nullif(trim(coalesce(new.extra ->> '最寄り駅', '')), ''), '通勤手段', nullif(trim(coalesce(new.extra ->> '通勤手段', '')), '')))); end if;
    if (nullif(trim(coalesce(new.phone, '')), ''), nullif(trim(coalesce(new.emergency_name, '')), ''), nullif(trim(coalesce(new.emergency_relation, '')), ''), nullif(trim(coalesce(new.emergency_phone, '')), ''), nullif(trim(coalesce(new.extra ->> 'contact_email', '')), ''))
       is distinct from (nullif(trim(coalesce(old.phone, '')), ''), nullif(trim(coalesce(old.emergency_name, '')), ''), nullif(trim(coalesce(old.emergency_relation, '')), ''), nullif(trim(coalesce(old.emergency_phone, '')), ''), nullif(trim(coalesce(old.extra ->> 'contact_email', '')), '')) then
      perform employee_change_record(new.user_id, 'contact', 'employee_profiles', 'update',
        jsonb_strip_nulls(jsonb_build_object('phone', nullif(trim(coalesce(old.phone, '')), ''), 'emergency_name', nullif(trim(coalesce(old.emergency_name, '')), ''), 'emergency_relation', nullif(trim(coalesce(old.emergency_relation, '')), ''), 'emergency_phone', nullif(trim(coalesce(old.emergency_phone, '')), ''), 'contact_email', nullif(trim(coalesce(old.extra ->> 'contact_email', '')), ''))),
        jsonb_strip_nulls(jsonb_build_object('phone', nullif(trim(coalesce(new.phone, '')), ''), 'emergency_name', nullif(trim(coalesce(new.emergency_name, '')), ''), 'emergency_relation', nullif(trim(coalesce(new.emergency_relation, '')), ''), 'emergency_phone', nullif(trim(coalesce(new.emergency_phone, '')), ''), 'contact_email', nullif(trim(coalesce(new.extra ->> 'contact_email', '')), '')))); end if;
    if new.hire_date is distinct from old.hire_date or new.termination_date is distinct from old.termination_date then
      perform employee_change_record(new.user_id, 'employment_status', 'employee_profiles', 'update', jsonb_strip_nulls(jsonb_build_object('hire_date', old.hire_date, 'termination_date', old.termination_date)), jsonb_strip_nulls(jsonb_build_object('hire_date', new.hire_date, 'termination_date', new.termination_date))); end if;
  exception when others then perform employee_change_log_error('employee_profiles', 'update', new.user_id, sqlerrm);
  end;
  return null;
end $$;

-- 所属店舗（文単位。全削除→入れ直しをまとめる）
create or replace function employee_change_trg_user_stores() returns trigger language plpgsql security definer set search_path = public as $$
declare u record; v_after jsonb; v_before jsonb;
begin
  begin
    for u in select user_id, jsonb_agg(store_id order by store_id::text) ids, (array_agg(store_id) filter (where is_primary))[1] prim from chg group by user_id loop
      v_after := employee_change_stores_state(u.user_id);
      if tg_op = 'INSERT' then
        v_before := jsonb_build_object('stores', coalesce((select jsonb_agg(x order by x #>> '{}') from jsonb_array_elements(v_after -> 'stores') x where not (u.ids @> jsonb_build_array(x))), '[]'::jsonb),
                                       'primary', case when u.prim is not null and (v_after ->> 'primary') = u.prim::text then null else v_after -> 'primary' end);
      elsif tg_op = 'DELETE' then
        v_before := jsonb_build_object('stores', (select coalesce(jsonb_agg(t order by t), '[]'::jsonb) from (select distinct x #>> '{}' t from (select jsonb_array_elements(v_after -> 'stores') x union all select jsonb_array_elements(u.ids)) y) z),
                                       'primary', coalesce(to_jsonb(u.prim), v_after -> 'primary'));
      else   -- UPDATE（主店舗の付け替え）
        v_before := jsonb_build_object('stores', v_after -> 'stores', 'primary', to_jsonb(u.prim));
      end if;
      perform employee_change_record(u.user_id, 'stores', 'user_stores', lower(tg_op), v_before, v_after);
    end loop;
  exception when others then perform employee_change_log_error('user_stores', lower(tg_op), null, sqlerrm);
  end;
  return null;
end $$;

create or replace function employee_change_trg_bank() returns trigger language plpgsql security definer set search_path = public as $$
declare b jsonb; a jsonb; v_user uuid;
begin
  if tg_op = 'DELETE' then v_user := old.user_id; else v_user := new.user_id; end if;
  begin
    if tg_op <> 'INSERT' then b := to_jsonb(old) - 'updated_at' - 'created_at' - 'updated_by' - 'user_id'; end if;
    if tg_op <> 'DELETE' then a := to_jsonb(new) - 'updated_at' - 'created_at' - 'updated_by' - 'user_id'; end if;
    perform employee_change_record(v_user, 'bank_account', 'payroll_bank_accounts', lower(tg_op), b, a);
  exception when others then perform employee_change_log_error('payroll_bank_accounts', lower(tg_op), v_user, sqlerrm);
  end;
  return null;
end $$;

-- 賃金（同期状態だけの更新は記録しない。行ごとに 1 イベント＝適用開始日つき）
create or replace function employee_change_trg_wage() returns trigger language plpgsql security definer set search_path = public as $$
declare b jsonb; a jsonb; v_key text; v_user uuid; v_eff date;
begin
  if tg_op = 'DELETE' then v_user := old.user_id; v_key := old.id::text; v_eff := old.effective_date; else v_user := new.user_id; v_key := new.id::text; v_eff := new.effective_date; end if;
  begin
    if tg_op <> 'INSERT' then b := jsonb_build_object('contract_id', old.contract_id, 'division', old.division, 'store_id', old.store_id, 'wage', old.wage, 'holiday_wage', old.holiday_wage, 'effective_date', old.effective_date); end if;
    if tg_op <> 'DELETE' then a := jsonb_build_object('contract_id', new.contract_id, 'division', new.division, 'store_id', new.store_id, 'wage', new.wage, 'holiday_wage', new.holiday_wage, 'effective_date', new.effective_date); end if;
    if b is distinct from a then
      -- 賃金は行（適用開始日）ごとに別イベントにしたいので、まとめ用のグループは共通でも before/after に行の id を入れて区別する
      perform employee_change_record(v_user, 'wage', 'employee_wage_settings', lower(tg_op),
        case when b is null then null else jsonb_build_object(v_key, b) end, case when a is null then null else jsonb_build_object(v_key, a) end, v_eff);
    end if;
  exception when others then perform employee_change_log_error('employee_wage_settings', lower(tg_op), v_user, sqlerrm);
  end;
  return null;
end $$;

-- 申請の承認（承認の RPC が先に本体を更新し、あとで申請行を承認済みにする場合のひも付け）
create or replace function employee_change_trg_profile_request() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    if new.status = 'approved' and old.status is distinct from 'approved' then
      update employee_change_events set source = 'request', request_table = 'profile_change_requests', request_id = new.id,
             requested_by = new.requested_by, requested_at = new.requested_at, approved_by = new.reviewed_by, approved_at = coalesce(new.reviewed_at, now())
       where user_id = new.user_id and txid = txid_current() and field_group = employee_change_group_of_request(new.field) and request_id is null;
    end if;
  exception when others then perform employee_change_log_error('profile_change_requests', 'update', new.user_id, sqlerrm);
  end;
  return null;
end $$;

-- 交通費が再承認されたら、再確認を完了にする（結果＝旧額・新額・変わったか）。承認額の変更そのものは既存の onboarding_commute_decide が行う
create or replace function employee_change_trg_commute() returns trigger language plpgsql security definer set search_path = public as $$
declare f employee_change_effects%rowtype;
begin
  begin
    if new.recheck_effect_id is not null and new.judgement = 'approved' and (old.judgement is distinct from 'approved' or new.approved_at is distinct from old.approved_at) then
      select * into f from employee_change_effects where id = new.recheck_effect_id and status in ('pending','in_progress');
      if f.id is not null then
        update employee_change_effects set status = 'done', resolved_by = new.approved_by, resolved_at = now(), updated_at = now(),
               result = jsonb_build_object('old_fare', f.snapshot -> 'approved_fare', 'new_fare', new.approved_fare, 'changed', (f.snapshot ->> 'approved_fare')::int is distinct from new.approved_fare,
                                           'old_home_station', f.snapshot -> 'home_station', 'new_home_station', new.home_station,
                                           'next', case when (f.snapshot ->> 'approved_fare')::int is distinct from new.approved_fare then '交通費の設定（適用開始日を決めてスマレジへ）が必要' else '承認額は変わらないため設定の変更は不要' end)
         where id = f.id;
      end if;
      update employee_commute set recheck_required_at = null, recheck_effect_id = null, recheck_reason = null where user_id = new.user_id;
    end if;
  exception when others then perform employee_change_log_error('employee_commute', 'update', new.user_id, sqlerrm);
  end;
  return null;
end $$;

drop trigger if exists employee_change_users on users;
create trigger employee_change_users after update on users for each row execute function employee_change_trg_users();
drop trigger if exists employee_change_profiles on employee_profiles;
create trigger employee_change_profiles after update on employee_profiles for each row execute function employee_change_trg_profiles();
drop trigger if exists employee_change_user_stores_ins on user_stores;
create trigger employee_change_user_stores_ins after insert on user_stores referencing new table as chg for each statement execute function employee_change_trg_user_stores();
drop trigger if exists employee_change_user_stores_del on user_stores;
create trigger employee_change_user_stores_del after delete on user_stores referencing old table as chg for each statement execute function employee_change_trg_user_stores();
drop trigger if exists employee_change_user_stores_upd on user_stores;
create trigger employee_change_user_stores_upd after update on user_stores referencing old table as chg for each statement execute function employee_change_trg_user_stores();
drop trigger if exists employee_change_bank on payroll_bank_accounts;
create trigger employee_change_bank after insert or update or delete on payroll_bank_accounts for each row execute function employee_change_trg_bank();
drop trigger if exists employee_change_wage on employee_wage_settings;
create trigger employee_change_wage after insert or update or delete on employee_wage_settings for each row execute function employee_change_trg_wage();
drop trigger if exists employee_change_profile_request on profile_change_requests;
create trigger employee_change_profile_request after update on profile_change_requests for each row execute function employee_change_trg_profile_request();
drop trigger if exists employee_change_commute on employee_commute;
create trigger employee_change_commute after update on employee_commute for each row execute function employee_change_trg_commute();

-- ============ 8. 本部が使う RPC ============
-- 変更日・適用開始日をあとから入れる（過去日付も可。影響側の「さかのぼり」表示と目安を計算し直す）
create or replace function employee_change_set_dates(p_event uuid, p_change_date date, p_effective_date date default null, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; e employee_change_events%rowtype; v_hint jsonb; v_min date;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into e from employee_change_events where id = p_event for update;
  if e.id is null then raise exception '変更の記録が見つかりません'; end if;
  if p_change_date is not null and p_change_date > current_date + 366 then raise exception '変更日が先すぎます'; end if;
  update employee_change_events set change_date = p_change_date, effective_date = coalesce(p_effective_date, effective_date), updated_at = now() where id = p_event;
  -- この記録にひも付く未完了の影響: 変更日（最も早い日）と目安を計算し直す
  update employee_change_effects f set change_date = x.d, retroactive = coalesce((employee_change_effective_hint(x.d) ->> 'retroactive')::boolean, false),
         suggested_effective_date = (employee_change_effective_hint(x.d) ->> 'suggested_effective_date')::date, updated_at = now()
    from (select l.effect_id, min(ev.change_date) d from employee_change_effect_events l join employee_change_events ev on ev.id = l.event_id
           where l.effect_id in (select effect_id from employee_change_effect_events where event_id = p_event) group by l.effect_id) x
   where f.id = x.effect_id and f.status in ('pending','in_progress');
  return jsonb_build_object('ok', true, 'hint', employee_change_effective_hint(p_change_date));
end $$;

-- 影響を人が閉じる（「確認したが交通費は変わらない」「対象外」など。理由必須）。交通費そのものは変えない
create or replace function employee_change_effect_resolve(p_effect uuid, p_status text, p_note text, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; f employee_change_effects%rowtype;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_status not in ('done','not_needed','in_progress') then raise exception '状態が不正です'; end if;
  if p_status <> 'in_progress' and nullif(trim(coalesce(p_note, '')), '') is null then raise exception '理由を入れてください'; end if;
  select * into f from employee_change_effects where id = p_effect for update;
  if f.id is null then raise exception '対象が見つかりません'; end if;
  if f.status not in ('pending','in_progress') then raise exception 'すでに完了しています'; end if;
  if p_status = 'in_progress' then
    update employee_change_effects set status = 'in_progress', updated_at = now() where id = p_effect;
  else
    update employee_change_effects set status = p_status, resolved_by = v_actor, resolved_at = now(), resolve_note = trim(p_note), updated_at = now(),
           result = coalesce(result, '{}'::jsonb) || jsonb_build_object('closed_by_hand', true, 'changed', false) where id = p_effect;
    update employee_commute set recheck_required_at = null, recheck_effect_id = null, recheck_reason = null where recheck_effect_id = p_effect;
  end if;
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;

-- 一覧（本部系）。機微な項目の値は マスター・本部以外には伏せる（項目名・誰が・いつ は見える）
create or replace function employee_change_list(p_user uuid default null, p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_full boolean := is_profile_approver() or onboarding_is_service();
begin
  if not (hq_can_manage() or onboarding_is_service()) then raise exception '権限がありません（本部・社長・マスターのみ）'; end if;
  return jsonb_build_object(
    'can_see_values', v_full,
    'events', coalesce((select jsonb_agg(x order by x.created_at desc) from (
        select e.id, e.user_id, (select name from users u where u.id = e.user_id) user_name, e.field_group, r.label, r.sensitive, e.source, e.op, e.changed_keys, e.status,
               case when r.sensitive and not v_full then null else e.before end before, case when r.sensitive and not v_full then null else e.after end after,
               (select name from users u where u.id = e.changed_by) changed_by_name, (select name from users u where u.id = e.requested_by) requested_by_name, e.requested_at,
               (select name from users u where u.id = e.approved_by) approved_by_name, e.approved_at, e.change_date, e.effective_date, e.created_at,
               r.source_of_truth, r.external_targets
          from employee_change_events e join employee_change_rules r on r.field_group = e.field_group
         where (p_user is null or e.user_id = p_user) order by e.created_at desc limit greatest(1, least(coalesce(p_limit, 50), 200))) x), '[]'::jsonb),
    'effects', coalesce((select jsonb_agg(y order by y.created_at desc) from (
        select f.id, f.user_id, (select name from users u where u.id = f.user_id) user_name, f.effect_key, f.status, f.reasons, f.change_date, f.retroactive, f.suggested_effective_date,
               employee_change_effective_hint(f.change_date) ->> 'note' date_note, f.snapshot, f.result, f.notified_at, (select name from users u where u.id = f.resolved_by) resolved_by_name, f.resolved_at, f.resolve_note, f.created_at,
               (select jsonb_agg(l.event_id) from employee_change_effect_events l where l.effect_id = f.id) event_ids
          from employee_change_effects f
         where (p_user is null or f.user_id = p_user) and (p_user is not null or f.status in ('pending','in_progress')) order by f.created_at desc limit 200) y), '[]'::jsonb));
end $$;

-- 本人向け: 自分に「通勤経路の再確認」が出ているか（値は返さない）
create or replace function employee_change_my_recheck()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('required', exists (select 1 from employee_change_effects f where f.user_id = auth.uid() and f.effect_key = 'commute_recheck' and f.status in ('pending','in_progress')),
                            'reasons', (select f.reasons from employee_change_effects f where f.user_id = auth.uid() and f.effect_key = 'commute_recheck' and f.status in ('pending','in_progress') limit 1))
$$;

revoke all on function employee_change_record(uuid, text, text, text, jsonb, jsonb, date) from public, anon, authenticated;
revoke all on function employee_change_dispatch(uuid) from public, anon, authenticated;
revoke all on function employee_change_retract(uuid) from public, anon, authenticated;
revoke all on function employee_change_notify(uuid) from public, anon, authenticated;
revoke all on function employee_change_log_error(text, text, uuid, text) from public, anon, authenticated;
grant execute on function employee_change_set_dates(uuid, date, date, uuid) to authenticated, service_role;
grant execute on function employee_change_effect_resolve(uuid, text, text, uuid) to authenticated, service_role;
grant execute on function employee_change_list(uuid, integer) to authenticated, service_role;
grant execute on function employee_change_my_recheck() to authenticated;

-- ============ 9. 既存関数の差し替え（1 か所だけ） ============
-- onboarding_save_commute: 「承認済みの人が再申請しても承認済みのまま」を、再確認が出ているあいだだけやめる（本部の再承認が必要になる）。
--   承認額（approved_fare）・交通費設定・スマレジは触らない＝本部が再承認して設定するまで旧交通費のまま
CREATE OR REPLACE FUNCTION public.onboarding_save_commute(p_user uuid, p_method text, p_route_text text, p_claimed_fare integer, p_uses_bus boolean, p_note text, p_via text DEFAULT 'nippo_join'::text, p_actor uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_actor uuid; v_wf uuid; v_station text; v_before jsonb;
begin
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
  if p_method is not null and p_method not in ('train','bus','train_bus','bike','walk','car','other') then raise exception '通勤手段が不正です'; end if;
  if p_claimed_fare is not null and (p_claimed_fare < 0 or p_claimed_fare > 100000) then raise exception '片道交通費が不正です'; end if;
  select id into v_wf from onboarding_workflows where user_id = p_user;
  select extra ->> '最寄り駅' into v_station from employee_profiles where user_id = p_user;
  select to_jsonb(c) - 'search_result' into v_before from employee_commute c where c.user_id = p_user;
  insert into employee_commute(user_id, workflow_id, method, home_station, route_text, claimed_oneway_fare, uses_bus, special_note, submitted_at, submitted_via)
  values (p_user, v_wf, p_method, v_station, nullif(trim(coalesce(p_route_text, '')), ''), p_claimed_fare, p_uses_bus, nullif(trim(coalesce(p_note, '')), ''), now(), coalesce(p_via, 'nippo_join'))
  on conflict (user_id) do update set
    workflow_id = coalesce(employee_commute.workflow_id, excluded.workflow_id), method = excluded.method, home_station = coalesce(excluded.home_station, employee_commute.home_station),
    route_text = excluded.route_text, claimed_oneway_fare = excluded.claimed_oneway_fare, uses_bus = excluded.uses_bus, special_note = excluded.special_note,
    submitted_at = now(), submitted_via = excluded.submitted_via,
    -- 申請内容が変わったら判定をやり直す（承認済みは残す）
    judgement = case when employee_commute.judgement = 'approved' and employee_commute.recheck_required_at is null then 'approved' else null end, judgement_reasons = '{}'::text[], judged_at = null,
    updated_at = now();
  if v_wf is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (v_wf, 'commute_check', 'commute.submitted', v_actor, case when p_via like 'slack%' then 'slack' when auth.uid() is null then 'system' else 'nippo' end, v_before,
            jsonb_build_object('method', p_method, 'claimed_oneway_fare', p_claimed_fare, 'uses_bus', p_uses_bus, 'has_route', p_route_text is not null));
    -- 項目: 申請が来たら commute_check を pending に戻す（検索は EF commute-route が行う）
    update onboarding_items set state = 'pending', completion_source = null, completed_at = null, updated_at = now()
     where workflow_id = v_wf and item_key = 'commute_check' and state in ('pending','failed','manual_required','retry_wait');
  end if;
  return jsonb_build_object('ok', true, 'workflow_id', v_wf, 'home_station', v_station);
end $function$;
