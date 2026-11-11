-- 共通承認基盤（第 1 段階）と、賃金変更の 2 段階承認（本部確認 → 社長の最終承認）  2026-11-11
--   設計: docs/設計書_従業員情報変更の連動_2026-11-10.md §14・§17・§18
--   ★ 本番未適用（開発・テストのみ承認。適用は別途承認）。戻し方: 2026-11-11_approval_base_rollback.sql
--   前提: 2026-11-10_pay_change_requests.sql（適用済み。賃金・口座の申請と承認）
--
--   この SQL は「足すだけ」。既存の関数・表は 1 つも作り替えない（既存の列・制約・関数の定義は変えない）。
--   適用しただけでは何も変わらない: 承認ルート approval_routes.active が false のあいだ、下のトリガーは素通しで、いまの 1 段階の承認のまま動く。
--   切り替え（別途承認）: 2026-11-11_approval_wage_route_on.sql ／ 戻す: 2026-11-11_approval_wage_route_off.sql
--
--   再利用するもの（作り直さない）:
--     ・申請の表 profile_change_requests と申請の関数 hr_pay_change_request（賃金の申請はこれまでどおりここから）
--     ・賃金の登録 hr_save_wage（適用開始日つき）→ スマレジ同期（wage_push → 読み戻し）・変更履歴 employee_change_events
--     ・本部タスク（申請 1 件につき 1 件・承認／却下／取り下げで自動完了）・Slack 通知（pay_change_notify。フラグ OFF）
--     ・直接登録の禁止 employee_change_pay_guard（wage_approval_required。入社手続き中・その契約の初回の登録は通す＝入社時の初期賃金登録は止めない）
--   足すもの:
--     ・承認ルートの設定表 approval_routes（申請の種類ごとに、段階の並び・段階ごとの役割・期限・自己承認の扱い）
--     ・案件 approval_cases（申請 1 件につき 1 行。いまの段階・状態・期限・締め日）／操作の履歴 approval_actions（段階ごとに だれが・いつ・何をしたか。書き換え不可）
--     ・権限判定は 1 か所 approval_can_act／操作は 1 か所 hr_approval_act（確認・最終承認・却下・差し戻し・再申請・取り下げ）
--     ・ルートが有効な種類の申請は、この操作の関数を通さないと状態を変えられない（DB のトリガーで止める＝古い画面・古い関数からの 1 段階承認は通らない）
--
--   賃金のルール（2026-11-11 確定）:
--     ・本部確認（本部の役割の人。申請した人とは別の人）→ 社長の最終承認（社長の役割の本人だけ）。本部確認だけでは何も確定しない
--     ・マスター権限では省略できない（役割で判定する。マスターかどうかは見ない）
--     ・自分自身についての申請は、自分では操作できない
--     ・社長が不在でも、代理の最終承認者は置かない。期限を過ぎても自動では承認しない（期限は表示と通知のためだけ）
--     ・社長本人の賃金・役員報酬は、この申請の対象外（申請を受け付けない。直接登録の禁止フラグが ON のときは直接登録も止める）

-- ============ 1. 表 ============
create table if not exists approval_routes (
  request_type        text primary key,                       -- 申請の種類（profile_change_requests.field と同じ値。例 wage）
  label               text not null,                          -- 表示名（例 賃金の変更）
  source_table        text not null default 'profile_change_requests',
  active              boolean not null default false,         -- true＝この種類の申請はこのルートで承認する（false＝これまでどおり）
  stages              jsonb not null,                         -- 段階の並び [{key,label,roles[],master_ok,allow_requester,distinct_from_prior,due_hours,channel_key}]
  allow_self_approval boolean not null default false,         -- 申請した人が自分で承認してよいか（原則 false）
  block_target_roles  text[] not null default '{}',           -- この役割の人を対象にした申請は受け付けない（社長本人の賃金）
  block_target_message text,
  close_warn_days     integer not null default 7,             -- 給与の締め日の何日前から「締め前」の注意を出すか
  reminder            jsonb not null default '{"after_hours": 0, "every_hours": 24, "max": 5, "quiet_from": 22, "quiet_to": 8}'::jsonb,   -- 期限超過のリマインド（送信は第 3 段階）
  slack_fields        text[] not null default '{type,employee,stores,requested_at,effective_date,stage,confirmed_by,due,status}',     -- Slack に出してよい項目（金額・口座番号は出さない）
  updated_at          timestamptz not null default now()
);
create table if not exists approval_cases (
  id                  uuid primary key default gen_random_uuid(),
  request_type        text not null references approval_routes(request_type),
  source_table        text not null,
  source_id           uuid not null,
  user_id             uuid not null,                          -- 対象の従業員
  requested_by        uuid,
  requested_at        timestamptz not null default now(),
  stages              jsonb not null,                         -- 申請時点のルートの写し（あとで設定を変えても、進行中の案件の段階は変わらない）
  allow_self_approval boolean not null default false,
  stage_index         integer not null default 0,
  stage_key           text not null,
  status              text not null default 'pending' check (status in ('pending', 'returned', 'approved', 'rejected', 'cancelled')),
  round               integer not null default 1,             -- 差し戻し → 再申請のたびに 1 増える
  resubmit_count      integer not null default 0,
  effective_date      date,                                   -- 適用開始日（賃金）
  close_date          date,                                   -- 給与の締め日（適用開始月の末日）。締め前の注意に使う
  stage_entered_at    timestamptz not null default now(),
  stage_due_at        timestamptz,                            -- いまの段階の承認期限（過ぎても自動では承認しない）
  remind_count        integer not null default 0,
  last_reminded_at    timestamptz,
  slack_refs          jsonb not null default '{}'::jsonb,     -- Slack の親メッセージの控え（第 2 段階で使う）
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  closed_at           timestamptz,
  unique (source_table, source_id)
);
create index if not exists approval_cases_open_idx on approval_cases (status, stage_due_at) where status in ('pending', 'returned');
create index if not exists approval_cases_user_idx on approval_cases (user_id);
create table if not exists approval_actions (
  id          uuid primary key default gen_random_uuid(),
  case_id     uuid not null references approval_cases(id) on delete cascade,
  round       integer not null,
  stage_index integer not null,
  stage_key   text not null,
  action      text not null check (action in ('submit', 'confirm', 'approve', 'reject', 'return', 'resubmit', 'cancel', 'remind', 'system')),
  actor_id    uuid,
  via         text not null default 'system' check (via in ('nippo', 'portal', 'slack', 'system')),
  comment     text,
  detail      jsonb,
  at          timestamptz not null default clock_timestamp()   -- 同じ取引の中でも順番が分かるように、実際の時刻
);
create index if not exists approval_actions_case_idx on approval_actions (case_id, at);
alter table approval_routes enable row level security;
alter table approval_cases enable row level security;
alter table approval_actions enable row level security;
-- 画面からは読むだけ（書くのは関数だけ＝書き込みの方針は作らない）
drop policy if exists approval_routes_read on approval_routes;
create policy approval_routes_read on approval_routes for select using (hq_can_manage());
drop policy if exists approval_cases_read on approval_cases;
create policy approval_cases_read on approval_cases for select using (hq_can_manage() or requested_by = auth.uid());
drop policy if exists approval_actions_read on approval_actions;
create policy approval_actions_read on approval_actions for select using (hq_can_manage() or exists (select 1 from approval_cases c where c.id = case_id and c.requested_by = auth.uid()));

-- 操作の履歴は書き換え・削除できない（案件ごと消す場合だけ一緒に消える）
create or replace function approval_actions_guard() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' then raise exception '承認の操作履歴は書き換えできません'; end if;
  if tg_op = 'DELETE' and exists (select 1 from approval_cases c where c.id = old.case_id) then raise exception '承認の操作履歴は削除できません'; end if;
  return coalesce(new, old);
end $$;
drop trigger if exists approval_actions_guard on approval_actions;
create trigger approval_actions_guard before update or delete on approval_actions for each row execute function approval_actions_guard();

-- ルートの設定の検査。賃金は「2 段階以上・最後の段階は社長の役割だけ・マスターでの代用なし」を DB 側でも固定する（設定の書き間違いで緩まないように）
create or replace function approval_routes_guard() returns trigger language plpgsql as $$
declare st jsonb; n int;
begin
  if jsonb_typeof(new.stages) <> 'array' or jsonb_array_length(new.stages) = 0 then raise exception '承認ルートの段階が空です'; end if;
  n := jsonb_array_length(new.stages);
  for st in select * from jsonb_array_elements(new.stages) loop
    if nullif(st ->> 'key', '') is null or nullif(st ->> 'label', '') is null or jsonb_typeof(st -> 'roles') <> 'array' or jsonb_array_length(st -> 'roles') = 0 then
      raise exception '承認ルートの段階には key・label・roles が必要です';
    end if;
  end loop;
  if new.active and new.request_type not in ('wage') then raise exception 'この種類（%）は、まだ共通の承認に接続していません', new.request_type; end if;
  if new.request_type = 'wage' then
    st := new.stages -> (n - 1);
    if n < 2 or st -> 'roles' <> '["CEO"]'::jsonb or coalesce((st ->> 'master_ok')::boolean, false) then
      raise exception '賃金の承認ルートは 2 段階以上で、最後の段階は社長（CEO）の役割だけにしてください（マスター権限での代用は不可）';
    end if;
    if new.allow_self_approval then raise exception '賃金の承認ルートでは、自己承認を許可できません'; end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists approval_routes_guard on approval_routes;
create trigger approval_routes_guard before insert or update on approval_routes for each row execute function approval_routes_guard();

-- 初期ルート: 賃金＝本部確認 → 社長の最終承認。active=false（適用しただけでは切り替わらない）
insert into approval_routes(request_type, label, source_table, active, stages, block_target_roles, block_target_message)
values ('wage', '賃金の変更', 'profile_change_requests', false,
  '[{"key": "hq_check", "label": "本部確認", "roles": ["HQ"], "master_ok": false, "allow_requester": false, "distinct_from_prior": false, "due_hours": 48, "channel_key": "hq.jinji"},
    {"key": "president", "label": "社長の最終承認", "roles": ["CEO"], "master_ok": false, "allow_requester": true, "distinct_from_prior": true, "due_hours": 72, "channel_key": "hq.juyo_shonin"}]'::jsonb,
  '{CEO}', '社長本人の賃金・役員報酬は、この申請では変更できません（正式な決定手続きに基づく別の手続きになります）')
on conflict (request_type) do nothing;

-- ============ 2. 補助 ============
create or replace function approval_route_active(p_type text, p_source_table text default 'profile_change_requests') returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select r.active from approval_routes r where r.request_type = p_type and r.source_table = p_source_table), false)
$$;
create or replace function approval_role_label(p_roles jsonb) returns text language sql immutable as $$
  select coalesce(string_agg(case r when 'HQ' then '本部' when 'CEO' then '社長' when 'TENCHO' then '店長' else r end, '・'), '—') from jsonb_array_elements_text(p_roles) r
$$;
-- 操作者: ログインしている人（p_actor は無視＝なりすまし防止）。EF（Slack）から呼ばれたときだけ p_actor
create or replace function approval_resolve_actor(p_actor uuid) returns uuid language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is not null then v := auth.uid();
  elsif onboarding_is_service() then v := p_actor;
  else raise exception '認証が必要です'; end if;
  if v is null or not exists (select 1 from users u where u.id = v and u.is_active) then raise exception '操作者が特定できません'; end if;
  return v;
end $$;
create or replace function approval_via(p_opts jsonb) returns text language sql stable as $$
  select case when auth.uid() is not null then case when coalesce(p_opts ->> 'via', '') = 'portal' then 'portal' else 'nippo' end
              when onboarding_is_service() then case when coalesce(p_opts ->> 'via', '') = 'system' then 'system' else 'slack' end
              else 'system' end
$$;
-- 給与の締め（末日締め・翌月 15 日払い）に対する状況。締め日＝適用開始月の末日
--   finalized=その月の給与は確定済み／passed=締め日を過ぎた（まだ確定前）／soon=締め日が近い／ok
create or replace function approval_close_info(p_user uuid, p_effective date, p_warn_days integer default 7, p_today date default (now() at time zone 'Asia/Tokyo')::date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_close date; v_ym text; v_corp uuid; v_state text; v_days int;
begin
  if p_effective is null then return jsonb_build_object('state', 'none'); end if;
  v_close := (date_trunc('month', p_effective) + interval '1 month' - interval '1 day')::date;
  v_ym := to_char(p_effective, 'YYYY-MM');
  select s.corporation_id into v_corp from user_stores us join stores s on s.id = us.store_id where us.user_id = p_user order by us.is_primary desc, s.sort_order limit 1;
  v_days := v_close - p_today;
  v_state := case when exists (select 1 from payroll_finalized f where f.year_month = v_ym and (v_corp is null or f.corporation_id = v_corp)) then 'finalized'
                  when v_days < 0 then 'passed' when v_days <= coalesce(p_warn_days, 7) then 'soon' else 'ok' end;
  return jsonb_build_object('state', v_state, 'close_date', v_close, 'year_month', v_ym, 'days_left', v_days,
    'message', case v_state
      when 'finalized' then v_ym || ' 月分の給与は確定済みです（最終承認のときに止まります）'
      when 'passed' then v_ym || ' 月分の締め日（' || to_char(v_close, 'FMMM/FMDD') || '）を過ぎています。給与の確定までに最終承認されないと、変更前の賃金で計算されます'
      when 'soon' then v_ym || ' 月分の締め日（' || to_char(v_close, 'FMMM/FMDD') || '）まであと ' || v_days || ' 日です。締めまでに最終承認されないと、変更前の賃金で計算されます'
      else null end);
end $$;
-- 段階の承認期限: 入った時刻＋段階の期限。締め日（その日の 18 時）が先にあるときは、残りの段階に 1 日ずつ残して前倒しする。過ぎても自動では承認しない
create or replace function approval_stage_due(p_stages jsonb, p_index integer, p_close_date date, p_now timestamptz default now())
returns timestamptz language plpgsql immutable as $$
declare v_due timestamptz; v_close timestamptz; v_cap timestamptz;
begin
  v_due := p_now + make_interval(hours => coalesce((p_stages -> p_index ->> 'due_hours')::int, 48));
  if p_close_date is not null then
    v_close := (p_close_date::timestamp + time '18:00') at time zone 'Asia/Tokyo';
    if v_close > p_now then
      v_cap := v_close - make_interval(hours => 24 * (jsonb_array_length(p_stages) - 1 - p_index));
      v_due := least(v_due, greatest(v_cap, least(p_now + interval '4 hours', v_close)));
    end if;
  end if;
  return v_due;
end $$;

-- ============ 3. 権限判定（ここ 1 か所。管理画面・ポータル・Slack のどこから来ても同じ） ============
create or replace function approval_can_act(p_case uuid, p_actor uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c approval_cases%rowtype; st jsonb; u users%rowtype;
begin
  select * into c from approval_cases where id = p_case;
  if c.id is null then return jsonb_build_object('ok', false, 'reason', '対象の申請が見つかりません'); end if;
  if c.status = 'returned' then return jsonb_build_object('ok', false, 'reason', '差し戻し中です（申請した人の修正・再申請を待っています）'); end if;
  if c.status <> 'pending' then return jsonb_build_object('ok', false, 'reason', 'この申請は既に処理済みです'); end if;
  st := c.stages -> c.stage_index;
  select * into u from users where id = p_actor;
  if u.id is null or not coalesce(u.is_active, false) then return jsonb_build_object('ok', false, 'reason', '操作者が特定できません'); end if;
  -- 役割で判定する。マスター権限は、段階の設定で明示されたときだけ（賃金のルートでは不可）
  if not (u.role in (select jsonb_array_elements_text(st -> 'roles')) or (coalesce((st ->> 'master_ok')::boolean, false) and coalesce(u.is_master, false))) then
    return jsonb_build_object('ok', false, 'reason', '「' || (st ->> 'label') || '」ができるのは、' || approval_role_label(st -> 'roles') || 'の役割の人だけです（マスター権限でも省略できません）');
  end if;
  if p_actor = c.user_id then return jsonb_build_object('ok', false, 'reason', '自分自身についての申請は、自分では承認できません'); end if;
  if p_actor = c.requested_by and not c.allow_self_approval and not coalesce((st ->> 'allow_requester')::boolean, false) then
    return jsonb_build_object('ok', false, 'reason', '申請した人とは別の人が行ってください');
  end if;
  if coalesce((st ->> 'distinct_from_prior')::boolean, false) and exists (select 1 from approval_actions a where a.case_id = c.id and a.round = c.round and a.action = 'confirm' and a.actor_id = p_actor) then
    return jsonb_build_object('ok', false, 'reason', '前の段階を確認した人とは別の人が行ってください');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ============ 4. 案件を開く（申請 1 件につき 1 行。ルートが有効な種類だけ） ============
create or replace function approval_case_open(p_request uuid, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare q profile_change_requests%rowtype; r approval_routes%rowtype; v_id uuid; v_close date;
begin
  select * into q from profile_change_requests where id = p_request;
  if q.id is null or q.status <> 'pending' then return null; end if;
  select * into r from approval_routes where request_type = q.field and source_table = 'profile_change_requests' and active;
  if r.request_type is null then return null; end if;
  v_close := case when q.effective_date is not null then (date_trunc('month', q.effective_date) + interval '1 month' - interval '1 day')::date end;
  insert into approval_cases(request_type, source_table, source_id, user_id, requested_by, requested_at, stages, allow_self_approval, stage_index, stage_key, effective_date, close_date, stage_due_at)
  values (r.request_type, 'profile_change_requests', q.id, q.user_id, q.requested_by, q.requested_at, r.stages, r.allow_self_approval, 0, r.stages -> 0 ->> 'key', q.effective_date, v_close,
          approval_stage_due(r.stages, 0, v_close))
  on conflict (source_table, source_id) do nothing returning id into v_id;
  if v_id is not null then
    insert into approval_actions(case_id, round, stage_index, stage_key, action, actor_id, via, comment, detail)
    values (v_id, 1, 0, r.stages -> 0 ->> 'key', 'submit', q.requested_by, approval_via('{}'::jsonb), q.request_reason, case when p_note is not null then jsonb_build_object('note', p_note) end);
  end if;
  return v_id;
end $$;
-- ルートを有効にした時点で承認待ちだった申請に、案件を付ける（最初の段階から）
create or replace function approval_cases_backfill() returns integer language plpgsql security definer set search_path = public as $$
declare q record; n integer := 0;
begin
  for q in select p.id from profile_change_requests p join approval_routes r on r.request_type = p.field and r.source_table = 'profile_change_requests' and r.active
            where p.status = 'pending' and not exists (select 1 from approval_cases c where c.source_table = 'profile_change_requests' and c.source_id = p.id) loop
    if approval_case_open(q.id, 'ルートを有効にした時点で承認待ちだった申請') is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;
create or replace function approval_routes_after() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.active and (tg_op = 'INSERT' or not old.active) then perform approval_cases_backfill(); end if;
  return null;
end $$;
drop trigger if exists approval_routes_after on approval_routes;
create trigger approval_routes_after after insert or update on approval_routes for each row execute function approval_routes_after();

-- ============ 5. 本部タスクとの連動（申請時に作られた本部タスクがあるときだけ。無ければ何もしない） ============
--   いまやること（本部確認／社長の最終承認／差し戻しの修正）を 1 行ずつ足し、済んだ行は完了にする。失敗しても承認そのものは止めない
create or replace function approval_task_sync(p_case uuid, p_actor uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare c approval_cases%rowtype; v_task uuid; st jsonb; v_title text; v_assignee uuid; v_step uuid; v_first uuid;
begin
  select * into c from approval_cases where id = p_case;
  if c.id is null or c.source_table <> 'profile_change_requests' then return; end if;
  select hq_task_id into v_task from profile_change_requests where id = c.source_id;
  if v_task is null then return; end if;
  begin
    st := c.stages -> c.stage_index;
    if c.status = 'returned' then
      v_title := '差し戻し: 申請した人が修正して再申請（または取り下げ）'; v_assignee := c.requested_by;
    elsif c.status = 'pending' then
      v_title := (st ->> 'label') || '（' || approval_role_label(st -> 'roles') || '）' || case when c.stage_index < jsonb_array_length(c.stages) - 1 then '※ ここでは確定しません' else '' end;
      select s.assignee_id into v_first from hq_task_steps s where s.task_id = v_task order by s.sort_order, s.created_at limit 1;
      select u.id into v_assignee from users u
       where u.is_active and u.role in (select jsonb_array_elements_text(st -> 'roles')) and u.id <> c.user_id
         and (coalesce((st ->> 'allow_requester')::boolean, false) or u.id is distinct from c.requested_by)
       order by (u.id = v_first) desc, u.created_at limit 1;
    else
      return;   -- 承認・却下・取り下げは、既存の自動完了（pay_change_task_close）に任せる
    end if;
    insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date)
    values (v_task, v_title, v_assignee, (select coalesce(max(sort_order), 0) + 10 from hq_task_steps where task_id = v_task), 'step', (c.stage_due_at at time zone 'Asia/Tokyo')::date)
    returning id into v_step;
    update hq_task_steps set completed_at = now(), completed_by = p_actor where task_id = v_task and completed_at is null and id <> v_step;
    insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, p_actor, 'comment', p_note);
  exception when others then perform employee_change_log_error('approval_cases', 'task_sync', c.user_id, sqlerrm);
  end;
end $$;
-- 申請時に作られた本部タスク（1 段階の文面）を、ルートに合わせた文面にする
create or replace function approval_task_relabel(p_case uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c approval_cases%rowtype; v_task uuid; st jsonb; v_flow text;
begin
  select * into c from approval_cases where id = p_case;
  if c.id is null then return; end if;
  select hq_task_id into v_task from profile_change_requests where id = c.source_id;
  if v_task is null or jsonb_array_length(c.stages) < 2 then return; end if;
  begin
    st := c.stages -> c.stage_index;
    select string_agg(x ->> 'label', ' → ' order by o) into v_flow from jsonb_array_elements(c.stages) with ordinality t(x, o);
    update hq_task_steps set title = (st ->> 'label') || '（' || approval_role_label(st -> 'roles') || '。申請した人とは別の人）※ ここでは確定しません', due_date = (c.stage_due_at at time zone 'Asia/Tokyo')::date
     where task_id = v_task and completed_at is null;
    update hq_tasks set description = coalesce(description, '') || E'\n' || '※ この申請は「' || v_flow || '」の順に進みます。最後の承認まで、賃金は変わりません。' where id = v_task and coalesce(description, '') not like '%の順に進みます%';
  exception when others then perform employee_change_log_error('approval_cases', 'task_relabel', c.user_id, sqlerrm);
  end;
end $$;

-- ============ 6. 確定の処理（最後の段階の承認のときだけ。中身は既存の賃金登録をそのまま呼ぶ） ============
create or replace function approval_finalize_wage(p_request uuid, p_actor uuid, p_force_closed boolean, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare q profile_change_requests%rowtype; v_ym text; v_corp uuid; r jsonb; v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  select * into q from profile_change_requests where id = p_request and status = 'pending' for update;
  if q.id is null or q.field <> 'wage' then raise exception '対象の申請が見つからないか、既に処理済みです'; end if;
  v_ym := to_char(q.effective_date, 'YYYY-MM');
  select s.corporation_id into v_corp from user_stores us join stores s on s.id = us.store_id where us.user_id = q.user_id order by us.is_primary desc, s.sort_order limit 1;
  -- 給与確定済みの月は自動で上書きしない。最終承認者（社長）が理由つきで明示したときだけ
  if exists (select 1 from payroll_finalized f where f.year_month = v_ym and (v_corp is null or f.corporation_id = v_corp)) then
    if not (coalesce(p_force_closed, false) and v_reason is not null) then
      update profile_change_requests set apply_status = 'blocked_finalized', apply_note = v_ym || ' の給与は確定済みのため自動では反映しません（差し戻して適用開始日を直すか、社長が理由つきで明示して最終承認）' where id = q.id;
      return jsonb_build_object('ok', false, 'blocked', 'finalized', 'error', v_ym || ' の給与は確定済みです。自動では上書きしません');
    end if;
  end if;
  update profile_change_requests set status = 'approved', reviewed_by = p_actor, reviewed_at = now(), reject_reason = null,
         apply_note = case when coalesce(p_force_closed, false) and v_reason is not null then '確定済みの月への反映を社長が承認: ' || v_reason else null end where id = q.id;
  perform set_config('employee_change.via_approval', q.id::text, true);
  r := hr_save_wage(q.user_id, q.payload ->> 'contract_id', (q.payload ->> 'division')::int, nullif(q.payload ->> 'store_id', '')::uuid, (q.payload ->> 'wage')::int, nullif(q.payload ->> 'holiday_wage', '')::int, q.effective_date, p_actor);
  perform set_config('employee_change.via_approval', '', true);
  update profile_change_requests set apply_status = 'applied', applied_at = now(), apply_ref = jsonb_build_object('wage_setting_id', r ->> 'id') where id = q.id;
  update employee_change_events set source = 'request', request_table = 'profile_change_requests', request_id = q.id, requested_by = q.requested_by, requested_at = q.requested_at, approved_by = p_actor, approved_at = now()
   where user_id = q.user_id and field_group = 'wage' and txid = txid_current();
  -- スマレジへの同期はここでは行わない（登録された行は sync_status=pending。既存の賃金同期＝wage_push → 読み戻し wage_pull が拾う）
  return jsonb_build_object('ok', true, 'apply_status', 'applied', 'wage_setting_id', r ->> 'id', 'sync', 'pending');
end $$;

-- ============ 7. 操作（ここ 1 か所）: approve＝いまの段階を通す（途中の段階は「確認」、最後の段階は「最終承認」）／reject／return＝差し戻し／resubmit＝再申請／cancel＝取り下げ ============
--   p_opts: force_closed（確定済みの月への反映。最後の段階・理由つき）／via（portal）／再申請の中身 payload・effective_date・reason
create or replace function hr_approval_act(p_case uuid, p_action text, p_comment text default null, p_actor uuid default null, p_opts jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c approval_cases%rowtype; q profile_change_requests%rowtype; v_actor uuid; v_can jsonb; st jsonb; nx jsonb; v_n int; v_via text; r jsonb;
  v_comment text := nullif(trim(coalesce(p_comment, '')), ''); v_opts jsonb := coalesce(p_opts, '{}'::jsonb);
  v_payload jsonb; v_date date; v_old jsonb; v_close date; v_role text; v_block text[]; v_msg text; v_hq boolean; v_warn text[] := '{}'; v_ci jsonb; v_before jsonb;
begin
  v_actor := approval_resolve_actor(p_actor);
  select * into c from approval_cases where id = p_case for update;
  if c.id is null then raise exception '対象の申請が見つかりません'; end if;
  if c.status not in ('pending', 'returned') then raise exception 'この申請は既に処理済みです'; end if;
  if c.source_table <> 'profile_change_requests' then raise exception 'この種類の申請は、まだ共通の承認に接続していません'; end if;
  select * into q from profile_change_requests where id = c.source_id for update;
  if q.id is null or q.status <> 'pending' then raise exception '元の申請が見つからないか、既に処理済みです'; end if;
  v_n := jsonb_array_length(c.stages); st := c.stages -> c.stage_index; v_via := approval_via(v_opts);
  if p_action in ('approve', 'reject', 'return') then
    v_can := approval_can_act(c.id, v_actor);
    if not (v_can ->> 'ok')::boolean then raise exception '%', v_can ->> 'reason'; end if;
  end if;
  perform set_config('approval.in_act', q.id::text, true);

  if p_action = 'approve' then
    select r2.block_target_roles, r2.block_target_message into v_block, v_msg from approval_routes r2 where r2.request_type = c.request_type;
    select role into v_role from users where id = c.user_id;
    if v_role = any(coalesce(v_block, '{}')) then raise exception '%', coalesce(v_msg, 'この人を対象にした申請は、この手順では承認できません'); end if;
    if c.stage_index < v_n - 1 then
      -- 途中の段階: 確認の記録だけ。この時点では何も確定しない（賃金は変わらない・スマレジにも送らない）
      nx := c.stages -> (c.stage_index + 1);
      insert into approval_actions(case_id, round, stage_index, stage_key, action, actor_id, via, comment) values (c.id, c.round, c.stage_index, c.stage_key, 'confirm', v_actor, v_via, v_comment);
      update approval_cases set stage_index = c.stage_index + 1, stage_key = nx ->> 'key', stage_entered_at = now(), stage_due_at = approval_stage_due(c.stages, c.stage_index + 1, c.close_date),
             remind_count = 0, last_reminded_at = null, updated_at = now() where id = c.id;
      update profile_change_requests set apply_status = 'none', apply_note = (st ->> 'label') || '済み（' || (nx ->> 'label') || '待ち）' where id = q.id;
      perform approval_task_sync(c.id, v_actor, (st ->> 'label') || 'が済みました。次は「' || (nx ->> 'label') || '」です（まだ確定していません）');
      v_ci := approval_close_info(c.user_id, c.effective_date);
      if v_ci ->> 'message' is not null then v_warn := v_warn || (v_ci ->> 'message'); end if;
      perform set_config('approval.in_act', '', true);
      return jsonb_build_object('ok', true, 'final', false, 'status', 'pending', 'stage_key', nx ->> 'key', 'stage_label', nx ->> 'label',
        'message', (st ->> 'label') || 'を記録しました。「' || (nx ->> 'label') || '」が済むまで、何も変わりません', 'warnings', to_jsonb(v_warn));
    end if;
    -- 最後の段階: 既存の確定処理へ
    if c.request_type = 'wage' then r := approval_finalize_wage(q.id, v_actor, coalesce((v_opts ->> 'force_closed')::boolean, false), v_comment);
    else raise exception 'この種類の申請は、まだ共通の承認に接続していません'; end if;
    if not coalesce((r ->> 'ok')::boolean, false) then
      perform set_config('approval.in_act', '', true);
      return r || jsonb_build_object('final', true, 'status', 'pending');
    end if;
    insert into approval_actions(case_id, round, stage_index, stage_key, action, actor_id, via, comment, detail)
    values (c.id, c.round, c.stage_index, c.stage_key, 'approve', v_actor, v_via, v_comment, case when coalesce((v_opts ->> 'force_closed')::boolean, false) then jsonb_build_object('force_closed', true) end);
    update approval_cases set status = 'approved', closed_at = now(), updated_at = now() where id = c.id;
    perform set_config('approval.in_act', '', true);
    return r || jsonb_build_object('final', true, 'status', 'approved', 'message', '最終承認して反映しました');

  elsif p_action = 'reject' then
    if v_comment is null then raise exception '却下の理由を入れてください'; end if;
    update profile_change_requests set status = 'rejected', reviewed_by = v_actor, reviewed_at = now(), reject_reason = v_comment where id = q.id;
    insert into approval_actions(case_id, round, stage_index, stage_key, action, actor_id, via, comment) values (c.id, c.round, c.stage_index, c.stage_key, 'reject', v_actor, v_via, v_comment);
    update approval_cases set status = 'rejected', closed_at = now(), updated_at = now() where id = c.id;
    perform set_config('approval.in_act', '', true);
    return jsonb_build_object('ok', true, 'status', 'rejected', 'message', '却下しました（何も変わっていません）');

  elsif p_action = 'return' then
    if v_comment is null then raise exception '差し戻しの理由を入れてください'; end if;
    insert into approval_actions(case_id, round, stage_index, stage_key, action, actor_id, via, comment) values (c.id, c.round, c.stage_index, c.stage_key, 'return', v_actor, v_via, v_comment);
    update approval_cases set status = 'returned', stage_due_at = null, remind_count = 0, last_reminded_at = null, updated_at = now() where id = c.id;
    update profile_change_requests set apply_status = 'none', apply_note = '差し戻し中（申請した人の修正待ち）: ' || v_comment where id = q.id;
    perform approval_task_sync(c.id, v_actor, '差し戻しました（申請した人が修正して再申請します）');
    perform set_config('approval.in_act', '', true);
    return jsonb_build_object('ok', true, 'status', 'returned', 'message', '差し戻しました（申請した人が直して再申請できます。何も変わっていません）');

  elsif p_action = 'resubmit' then
    if c.status <> 'returned' then raise exception '再申請できるのは、差し戻された申請だけです'; end if;
    if v_actor is distinct from c.requested_by then raise exception '再申請できるのは、申請した人だけです'; end if;
    v_payload := coalesce(v_opts -> 'payload', q.payload); v_date := coalesce(nullif(v_opts ->> 'effective_date', '')::date, q.effective_date);
    if c.request_type = 'wage' then
      if v_date is null then raise exception '適用開始日を指定してください'; end if;
      if coalesce((v_payload ->> 'wage')::int, 0) <= 0 or (v_payload ->> 'contract_id') is null or (v_payload ->> 'division') is null then raise exception '賃金の内容（契約・給与形態・金額）が足りません'; end if;
      if exists (select 1 from profile_change_requests p where p.id <> q.id and p.user_id = q.user_id and p.field = 'wage' and p.status = 'pending' and p.effective_date = v_date
                 and p.payload ->> 'contract_id' = v_payload ->> 'contract_id' and p.payload ->> 'division' = v_payload ->> 'division' and coalesce(p.payload ->> 'store_id', '') = coalesce(v_payload ->> 'store_id', '')) then
        raise exception '同じ適用開始日の賃金変更がすでに承認待ちです';
      end if;
      select jsonb_build_object('wage', w.wage, 'holiday_wage', w.holiday_wage, 'effective_date', w.effective_date) into v_old from employee_wage_settings w
       where w.user_id = q.user_id and w.contract_id = v_payload ->> 'contract_id' and w.division = (v_payload ->> 'division')::int and coalesce(w.store_id::text, '') = coalesce(v_payload ->> 'store_id', '') and w.effective_date <= v_date
       order by w.effective_date desc limit 1;
    else v_old := q.old_value::jsonb; end if;
    v_before := jsonb_build_object('payload', q.payload, 'effective_date', q.effective_date, 'reason', q.request_reason);
    update profile_change_requests set payload = v_payload, new_value = v_payload::text, old_value = v_old::text, effective_date = v_date,
           request_reason = coalesce(nullif(trim(coalesce(v_opts ->> 'reason', '')), ''), q.request_reason), apply_status = 'none', apply_note = null where id = q.id;
    v_close := case when v_date is not null then (date_trunc('month', v_date) + interval '1 month' - interval '1 day')::date end;
    insert into approval_actions(case_id, round, stage_index, stage_key, action, actor_id, via, comment, detail)
    values (c.id, c.round + 1, 0, c.stages -> 0 ->> 'key', 'resubmit', v_actor, v_via, v_comment,
            jsonb_build_object('before', v_before, 'after', jsonb_build_object('payload', v_payload, 'effective_date', v_date, 'reason', coalesce(nullif(trim(coalesce(v_opts ->> 'reason', '')), ''), q.request_reason))));
    update approval_cases set status = 'pending', round = c.round + 1, resubmit_count = c.resubmit_count + 1, stage_index = 0, stage_key = c.stages -> 0 ->> 'key', effective_date = v_date, close_date = v_close,
           stage_entered_at = now(), stage_due_at = approval_stage_due(c.stages, 0, v_close), remind_count = 0, last_reminded_at = null, updated_at = now() where id = c.id;
    perform approval_task_sync(c.id, v_actor, '修正して再申請されました（最初の段階からやり直します）');
    v_ci := approval_close_info(c.user_id, v_date);
    if v_ci ->> 'message' is not null then v_warn := v_warn || (v_ci ->> 'message'); end if;
    perform set_config('approval.in_act', '', true);
    return jsonb_build_object('ok', true, 'status', 'pending', 'stage_key', c.stages -> 0 ->> 'key', 'stage_label', c.stages -> 0 ->> 'label', 'message', '再申請しました（' || (c.stages -> 0 ->> 'label') || 'からやり直します）', 'warnings', to_jsonb(v_warn));

  elsif p_action = 'cancel' then
    select (u.is_master or u.role in ('CEO', 'HQ')) into v_hq from users u where u.id = v_actor;
    if v_actor is distinct from c.requested_by and not coalesce(v_hq, false) then raise exception '取り下げできるのは、申請した人か本部の人だけです'; end if;
    update profile_change_requests set status = 'cancelled', reviewed_by = v_actor, reviewed_at = now() where id = q.id;
    insert into approval_actions(case_id, round, stage_index, stage_key, action, actor_id, via, comment) values (c.id, c.round, c.stage_index, c.stage_key, 'cancel', v_actor, v_via, v_comment);
    update approval_cases set status = 'cancelled', closed_at = now(), updated_at = now() where id = c.id;
    perform set_config('approval.in_act', '', true);
    return jsonb_build_object('ok', true, 'status', 'cancelled', 'message', '取り下げました');
  end if;
  raise exception '操作の種類が不正です';
end $$;

-- ============ 8. 申請の表のトリガー（ルートが有効な種類だけ。無効のあいだは素通し） ============
-- 8a. 受付の検査と、操作の関数を通らない状態変更の禁止（古い画面・古い関数からの 1 段階承認を DB 側で止める）
create or replace function approval_request_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare r approval_routes%rowtype; v_role text; v_flow text;
begin
  select * into r from approval_routes where request_type = new.field and source_table = 'profile_change_requests' and active;
  if r.request_type is null then return new; end if;
  if tg_op = 'INSERT' then
    if new.status = 'pending' then
      select role into v_role from users where id = new.user_id;
      if v_role = any(r.block_target_roles) then raise exception '%', coalesce(r.block_target_message, 'この人を対象にした申請は受け付けていません'); end if;
    end if;
    return new;
  end if;
  if coalesce(current_setting('approval.in_act', true), '') = old.id::text then return new; end if;   -- 操作の関数からの書き込み
  if old.status = 'pending' and (new.status is distinct from old.status or new.payload is distinct from old.payload or new.new_value is distinct from old.new_value
       or new.effective_date is distinct from old.effective_date or new.requested_by is distinct from old.requested_by or new.user_id is distinct from old.user_id
       or new.apply_status is distinct from old.apply_status) then
    select string_agg(x ->> 'label', ' → ' order by o) into v_flow from jsonb_array_elements(r.stages) with ordinality t(x, o);
    raise exception '%は「%」の手順で行います。画面を再読み込みしてから、承認の画面で操作してください', r.label, v_flow;
  end if;
  return new;
end $$;
drop trigger if exists approval_request_guard on profile_change_requests;
create trigger approval_request_guard before insert or update on profile_change_requests for each row execute function approval_request_guard();

-- 8b. 申請が出来たら案件を開く。操作の関数を通らずに申請が閉じたとき（ルートを無効に戻したあとなど）は、案件も同じ状態で閉じる
create or replace function approval_request_after() returns trigger language plpgsql security definer set search_path = public as $$
declare v_case uuid; c approval_cases%rowtype;
begin
  if tg_op = 'INSERT' then
    if new.status = 'pending' then perform approval_case_open(new.id); end if;
    return null;
  end if;
  if coalesce(current_setting('approval.in_act', true), '') = new.id::text then return null; end if;
  if new.status = 'pending' then
    select id into v_case from approval_cases where source_table = 'profile_change_requests' and source_id = new.id;
    if v_case is null then v_case := approval_case_open(new.id); end if;
    if v_case is not null and old.hq_task_id is null and new.hq_task_id is not null then perform approval_task_relabel(v_case); end if;
  elsif old.status = 'pending' then
    select * into c from approval_cases where source_table = 'profile_change_requests' and source_id = new.id and status in ('pending', 'returned') for update;
    if c.id is not null then
      update approval_cases set status = new.status, closed_at = now(), updated_at = now() where id = c.id;
      insert into approval_actions(case_id, round, stage_index, stage_key, action, actor_id, via, comment, detail)
      values (c.id, c.round, c.stage_index, c.stage_key, 'system', new.reviewed_by, 'system', '共通の承認を通らずに申請が閉じられました', jsonb_build_object('status', new.status));
    end if;
  end if;
  return null;
end $$;
drop trigger if exists pay_change_request_approval_case on profile_change_requests;
create trigger pay_change_request_approval_case after insert or update on profile_change_requests for each row execute function approval_request_after();

-- 8c. 社長本人の賃金: 直接登録の禁止フラグ（wage_approval_required）が ON のときは、初回の登録・入社手続き中の例外も通さない。
--     システム処理（スマレジからの取込・同期状態の更新）は止めない
create or replace function approval_wage_target_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare r approval_routes%rowtype; v_user uuid; v_role text; v_human boolean;
begin
  select * into r from approval_routes where request_type = 'wage' and active;
  if r.request_type is null or cardinality(r.block_target_roles) = 0 then return coalesce(new, old); end if;
  if not coalesce((select (value ->> 'wage_approval_required')::boolean from app_settings where key = 'employee_change'), false) then return coalesce(new, old); end if;
  if coalesce(current_setting('employee_change.via_approval', true), '') <> '' then return coalesce(new, old); end if;
  if tg_op = 'UPDATE' and (new.wage, new.holiday_wage, new.effective_date, new.division, new.store_id, new.contract_id) is not distinct from (old.wage, old.holiday_wage, old.effective_date, old.division, old.store_id, old.contract_id) then return new; end if;
  v_human := auth.uid() is not null or (tg_op = 'INSERT' and new.created_by is not null);
  if not v_human then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then v_user := old.user_id; else v_user := new.user_id; end if;
  select role into v_role from users where id = v_user;
  if v_role = any(r.block_target_roles) then raise exception '%', coalesce(r.block_target_message, 'この人の賃金は、この画面では変更できません'); end if;
  return coalesce(new, old);
end $$;
drop trigger if exists approval_wage_target_guard on employee_wage_settings;
create trigger approval_wage_target_guard before insert or update or delete on employee_wage_settings for each row execute function approval_wage_target_guard();

-- ============ 9. 一覧（未承認の一覧・期限・締め前の注意）。金額・口座番号は返さない（詳細は従業員ページの申請の一覧で） ============
create or replace function approval_case_json(p_case uuid, p_viewer uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c approval_cases%rowtype; st jsonb; v_can jsonb; v_route approval_routes%rowtype; v_dead text; v_hq boolean;
begin
  select * into c from approval_cases where id = p_case;
  if c.id is null then return null; end if;
  st := c.stages -> c.stage_index;
  select * into v_route from approval_routes where request_type = c.request_type;
  v_can := case when p_viewer is null then jsonb_build_object('ok', false) else approval_can_act(c.id, p_viewer) end;
  select (u.is_master or u.role in ('CEO', 'HQ')) into v_hq from users u where u.id = p_viewer;
  v_dead := case when c.status <> 'pending' or c.stage_due_at is null then 'none' when now() > c.stage_due_at then 'overdue' when c.stage_due_at - now() < interval '24 hours' then 'soon' else 'ok' end;
  return jsonb_build_object('case_id', c.id, 'request_type', c.request_type, 'type_label', v_route.label, 'source_id', c.source_id,
    'user_id', c.user_id, 'user_name', (select name from users u where u.id = c.user_id),
    'stores', (select string_agg(s.name, '・' order by us.is_primary desc, s.sort_order) from user_stores us join stores s on s.id = us.store_id where us.user_id = c.user_id),
    'requested_by_name', (select name from users u where u.id = c.requested_by), 'requested_at', c.requested_at, 'effective_date', c.effective_date,
    'status', c.status, 'status_label', case c.status when 'pending' then (st ->> 'label') || '待ち' when 'returned' then '差し戻し中（申請した人の修正待ち）' when 'approved' then '承認済み' when 'rejected' then '却下' else '取り下げ' end,
    'stage_index', c.stage_index, 'stage_count', jsonb_array_length(c.stages), 'stage_key', c.stage_key, 'stage_label', st ->> 'label', 'stage_roles', approval_role_label(st -> 'roles'),
    'is_final_stage', c.stage_index = jsonb_array_length(c.stages) - 1,
    'flow', (select jsonb_agg(x ->> 'label' order by o) from jsonb_array_elements(c.stages) with ordinality t(x, o)),
    'stage_entered_at', c.stage_entered_at, 'stage_due_at', c.stage_due_at, 'deadline_state', v_dead,
    'close', case when c.status in ('pending', 'returned') then approval_close_info(c.user_id, c.effective_date, v_route.close_warn_days) else jsonb_build_object('state', 'none') end,
    'round', c.round, 'resubmit_count', c.resubmit_count, 'closed_at', c.closed_at,
    'confirmed_by_name', (select (select name from users u where u.id = a.actor_id) from approval_actions a where a.case_id = c.id and a.round = c.round and a.action = 'confirm' order by a.at desc limit 1),
    'can_act', coalesce((v_can ->> 'ok')::boolean, false), 'cannot_act_reason', v_can ->> 'reason',
    'can_resubmit', c.status = 'returned' and p_viewer is not null and p_viewer = c.requested_by,
    'can_cancel', c.status in ('pending', 'returned') and p_viewer is not null and (p_viewer = c.requested_by or coalesce(v_hq, false)),
    'mine', p_viewer is not null and p_viewer = c.requested_by,
    'history', (select coalesce(jsonb_agg(jsonb_build_object('action', a.action,
                   'action_label', case a.action when 'submit' then '申請' when 'confirm' then (c.stages -> a.stage_index ->> 'label') when 'approve' then (c.stages -> a.stage_index ->> 'label') when 'reject' then '却下'
                                    when 'return' then '差し戻し' when 'resubmit' then '再申請' when 'cancel' then '取り下げ' when 'remind' then 'リマインド' else '自動' end,
                   'stage_label', c.stages -> a.stage_index ->> 'label', 'round', a.round, 'actor_name', (select name from users u where u.id = a.actor_id), 'via', a.via, 'comment', a.comment, 'at', a.at) order by a.at, a.id), '[]'::jsonb)
                from approval_actions a where a.case_id = c.id));
end $$;

-- 本部系: 全件（p_user で 1 人に絞れる）。それ以外の人: 自分が申請したものだけ
create or replace function hr_approval_overview(p_user uuid default null, p_only_open boolean default true)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_viewer uuid := auth.uid(); v_all boolean := hq_can_manage() or onboarding_is_service(); v_cases jsonb;
begin
  if v_viewer is null and not onboarding_is_service() then raise exception '認証が必要です'; end if;
  select coalesce(jsonb_agg(x.j order by x.ord, x.due nulls last, x.req), '[]'::jsonb) into v_cases from (
    select approval_case_json(c.id, v_viewer) j, c.requested_at req, c.stage_due_at due,
           case when c.status = 'pending' and c.stage_due_at < now() then 0 when c.status = 'pending' then 1 when c.status = 'returned' then 2 else 3 end ord
      from approval_cases c
     where (v_all or c.requested_by = v_viewer) and (p_user is null or c.user_id = p_user)
       and (not coalesce(p_only_open, true) or c.status in ('pending', 'returned'))
     order by c.requested_at desc limit 200) x;
  return jsonb_build_object('ok', true, 'generated_at', now(),
    'routes', (select coalesce(jsonb_object_agg(r.request_type, jsonb_build_object('active', r.active, 'label', r.label,
                  'stages', (select jsonb_agg(jsonb_build_object('key', x ->> 'key', 'label', x ->> 'label', 'roles', approval_role_label(x -> 'roles')) order by o) from jsonb_array_elements(r.stages) with ordinality t(x, o)))), '{}'::jsonb)
                 from approval_routes r),
    'me', jsonb_build_object('id', v_viewer, 'role', (select role from users where id = v_viewer)),
    'counts', (select jsonb_build_object(
                  'open', count(*) filter (where x ->> 'status' in ('pending', 'returned')),
                  'returned', count(*) filter (where x ->> 'status' = 'returned'),
                  'overdue', count(*) filter (where x ->> 'deadline_state' = 'overdue'),
                  'close_warn', count(*) filter (where x ->> 'status' in ('pending', 'returned') and x -> 'close' ->> 'state' in ('soon', 'passed', 'finalized')),
                  'mine_to_act', count(*) filter (where (x ->> 'can_act')::boolean or (x ->> 'can_resubmit')::boolean),
                  'by_stage', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select y ->> 'stage_label' k, count(*) n from jsonb_array_elements(v_cases) y where y ->> 'status' = 'pending' group by 1) s))
                 from jsonb_array_elements(v_cases) x),
    'cases', v_cases);
end $$;

-- 画面から直接呼べるのは、操作 hr_approval_act と一覧 hr_approval_overview だけ。ほかは内部用（関数の中からだけ使う）
revoke all on function approval_route_active(text, text), approval_role_label(jsonb), approval_resolve_actor(uuid), approval_via(jsonb), approval_close_info(uuid, date, integer, date), approval_stage_due(jsonb, integer, date, timestamptz) from public, anon, authenticated;
revoke all on function approval_actions_guard(), approval_routes_guard(), approval_routes_after(), approval_request_guard(), approval_request_after(), approval_wage_target_guard() from public, anon, authenticated;
revoke all on function approval_case_open(uuid, text) from public, anon, authenticated;
revoke all on function approval_cases_backfill() from public, anon, authenticated;
revoke all on function approval_task_sync(uuid, uuid, text) from public, anon, authenticated;
revoke all on function approval_task_relabel(uuid) from public, anon, authenticated;
revoke all on function approval_finalize_wage(uuid, uuid, boolean, text) from public, anon, authenticated;
revoke all on function approval_case_json(uuid, uuid) from public, anon, authenticated;
revoke all on function approval_can_act(uuid, uuid) from public, anon, authenticated;
revoke all on function hr_approval_act(uuid, text, text, uuid, jsonb) from public, anon;
revoke all on function hr_approval_overview(uuid, boolean) from public, anon;
grant execute on function hr_approval_act(uuid, text, text, uuid, jsonb) to authenticated, service_role;
grant execute on function hr_approval_overview(uuid, boolean) to authenticated, service_role;
grant execute on function approval_case_open(uuid, text), approval_cases_backfill(), approval_task_sync(uuid, uuid, text), approval_task_relabel(uuid), approval_finalize_wage(uuid, uuid, boolean, text), approval_case_json(uuid, uuid), approval_can_act(uuid, uuid) to service_role;
