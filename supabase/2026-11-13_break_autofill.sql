-- 社員・店長の休憩の自動補完（2026-11-13）
--   設計: docs/設計書_勤怠修正画面と社員休憩自動補完_2026-11-12.md
--   ★ 本番未適用（実装・テストのみ承認。適用・有効化は別途承認）。戻し方: 2026-11-13_break_autofill_rollback.sql
--
--   適用しただけでは何も変わらない（既存の表・関数は作り替えない。足すのは表 2 つ・関数・設定 1 つ）。
--   動くのは、設定 app_settings.attendance_break_autofill.enabled が true で、Edge Function attendance-break-autofill が呼ばれたときだけ（既定 false）。
--
--   仕様（ユーザー確定 2026-11-11）:
--     ・対象: 社員・店長（アルバイトは対象外。役割で見る）のうち、月給の人（日給の人は対象外。時給だけの人も補完しない）。6 時間を超える勤務で、休憩が 1 つも登録されていないとき、60 分を補完する
--     ・登録済みの休憩は上書きしない／休憩を取っていない・短かったという申告がある日は補完しない／人が直した勤怠・申請や確認が出ている勤怠は補完しない
--     ・給与確定済みの月は対象外／同じ勤怠には 1 回だけ（二重登録の防止）／スマレジ側で休憩が自動で引かれている疑いがあれば補完しない（二重控除の防止）
--     ・推定した時刻は「推定」として履歴に残す。あとから実際の時刻に直されたら「置き換えられた」と残す
--     ・通常は通知も承認もなし。同期の失敗・競合・例外だけを本部タスクに出す
--     ・スマレジ側の「休憩時間自動設定」と重ならないこと: 実行のたびにスマレジの設定を読み、有効な事業所・従業員区分があれば止める。読めないときは、
--       人が管理画面で確認した印（設定 smaregi_auto_break_confirmed_off=true）が無ければ動かない。そのうえで、勤怠ごとにも「休憩が入っていないか・勤務時間が引かれていないか」を確かめる

insert into app_settings(key, value) values ('attendance_break_autofill',
  '{"enabled": false, "roles": ["SHAIN", "TENCHO"], "min_span_minutes": 360, "break_minutes": 60, "lookback_days": 35, "max_per_run": 30, "max_attempts": 3, "deducted_tolerance_minutes": 30, "smaregi_auto_break_confirmed_off": false}'::jsonb)
on conflict (key) do nothing;

-- ============ 1. 補完の履歴（1 勤怠 1 行） ============
create table if not exists attendance_break_autofills (
  id                      uuid primary key default gen_random_uuid(),
  labor_cost_daily_id     uuid not null unique,          -- 1 勤怠に 1 回だけ（二重登録の防止）
  smaregi_shift_result_id text,
  contract_id             text,
  user_id                 uuid not null,
  store_id                uuid,
  work_date               date not null,
  before                  jsonb not null,                -- 補完の前の勤怠（出勤・退勤・休憩・勤務時間）
  est_break_start         timestamptz,                   -- 推定した休憩（開始・終了）
  est_break_end           timestamptz,
  est_minutes             integer,
  rule                    jsonb,                         -- 使ったルール（何分・置き場所）
  status                  text not null check (status in ('syncing', 'synced', 'error', 'conflict', 'skipped', 'superseded')),
  --  syncing＝同期の途中／synced＝スマレジに入った（いまの休憩は推定値）／error＝同期の失敗／conflict＝スマレジ側が変わっていた
  --  skipped＝補完しなかった（理由つき）／superseded＝あとから実際の時刻に置き換えられた
  reason                  text,
  attempts                integer not null default 1,
  smaregi_response        jsonb,
  created_at              timestamptz not null default now(),
  synced_at               timestamptz,
  updated_at              timestamptz not null default now(),
  superseded_at           timestamptz,
  task_noted_at           timestamptz                    -- 本部タスクに載せた日時
);
create index if not exists attendance_break_autofills_user_idx on attendance_break_autofills (user_id, work_date);
create index if not exists attendance_break_autofills_status_idx on attendance_break_autofills (status, updated_at);

-- ============ 2. 例外の申告（休憩を取っていない・短かった）。申告がある日は補完しない ============
create table if not exists attendance_break_exceptions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null,
  work_date    date not null,
  kind         text not null check (kind in ('none', 'short')),      -- none＝休憩を取っていない／short＝短かった
  minutes      integer check (minutes is null or (minutes between 1 and 59)),
  reason       text not null,
  declared_by  uuid not null,
  declared_at  timestamptz not null default now(),
  cancelled_at timestamptz,
  check ((kind = 'short') = (minutes is not null))
);
create unique index if not exists attendance_break_exceptions_live_uq on attendance_break_exceptions (user_id, work_date) where cancelled_at is null;
alter table attendance_break_autofills enable row level security;
alter table attendance_break_exceptions enable row level security;
drop policy if exists attendance_break_autofills_read on attendance_break_autofills;
create policy attendance_break_autofills_read on attendance_break_autofills for select using (hq_can_manage() or user_id = auth.uid());
drop policy if exists attendance_break_exceptions_read on attendance_break_exceptions;
create policy attendance_break_exceptions_read on attendance_break_exceptions for select using (hq_can_manage() or user_id = auth.uid() or declared_by = auth.uid());

create or replace function attendance_break_autofill_cfg() returns jsonb language sql stable security definer set search_path = public as $$
  select '{"enabled": false, "roles": ["SHAIN", "TENCHO"], "min_span_minutes": 360, "break_minutes": 60, "lookback_days": 35, "max_per_run": 30, "max_attempts": 3, "deducted_tolerance_minutes": 30, "smaregi_auto_break_confirmed_off": false}'::jsonb
         || coalesce((select value from app_settings where key = 'attendance_break_autofill'), '{}'::jsonb)
$$;

-- ============ 3. 対象の判定（ここ 1 か所） ============
--   休憩が未登録で、6 時間を超える、社員・店長の勤怠を返す。eligible＝補完してよい／skip_reason＝補完しない理由
create or replace function attendance_break_autofill_scan(p_from date default null, p_to date default null)
returns table(labor_cost_daily_id uuid, user_id uuid, store_id uuid, work_date date, clock_in timestamptz, clock_out timestamptz, span_minutes numeric, worked_minutes numeric,
              smaregi_shift_result_id text, contract_id text, eligible boolean, skip_reason text)
language sql stable security definer set search_path = public as $$
  with cfg as (select attendance_break_autofill_cfg() c),
  def as (select sc.contract_id from smaregi_contracts sc where sc.is_default limit 1),
  base as (
    select l.id, l.user_id, l.store_id, l.work_date, l.clock_in, l.clock_out, extract(epoch from (l.clock_out - l.clock_in)) / 60 span, l.worked_minutes, l.smaregi_shift_result_id, l.manual_fixed_at,
           case when l.smaregi_shift_result_id like '%:%' then split_part(l.smaregi_shift_result_id, ':', 1) else (select contract_id from def) end contract_id
      from labor_cost_daily l join users u on u.id = l.user_id, cfg
     where u.is_active and u.role in (select jsonb_array_elements_text(cfg.c -> 'roles'))
       and l.clock_in is not null and l.clock_out is not null
       and l.break_start_1 is null and l.break_end_1 is null and l.break_start_2 is null and l.break_end_2 is null and coalesce(l.break_minutes, 0) = 0
       and extract(epoch from (l.clock_out - l.clock_in)) / 60 > (cfg.c ->> 'min_span_minutes')::numeric
       and l.work_date >= coalesce(p_from, (now() at time zone 'Asia/Tokyo')::date - (cfg.c ->> 'lookback_days')::int)
       and l.work_date <= coalesce(p_to, (now() at time zone 'Asia/Tokyo')::date - 1))
  select b.id, b.user_id, b.store_id, b.work_date, b.clock_in, b.clock_out, round(b.span), b.worked_minutes, b.smaregi_shift_result_id, b.contract_id, r.reason is null, r.reason
    from base b, cfg, lateral (select case
      when exists (select 1 from attendance_break_autofills a where a.labor_cost_daily_id = b.id and (a.status <> 'error' or a.attempts >= (cfg.c ->> 'max_attempts')::int)) then 'already'
      when exists (select 1 from attendance_break_exceptions e where e.user_id = b.user_id and e.work_date = b.work_date and e.cancelled_at is null) then 'exception'
      when b.manual_fixed_at is not null then 'manual_fixed'
      when exists (select 1 from sf_attendance_alerts x where x.labor_cost_daily_id = b.id and x.status in ('open', 'fix_requested'))
        or exists (select 1 from sf_attendance_requests q where q.user_id = b.user_id and q.work_date = b.work_date and q.status = 'pending')
        or exists (select 1 from sf_attendance_smaregi_changes g where g.labor_cost_daily_id = b.id and g.status = 'open') then 'pending_request'
      when b.smaregi_shift_result_id is null or b.smaregi_shift_result_id like 'req:%' then 'no_smaregi_id'
      when exists (select 1 from payroll_finalized f join smaregi_contracts sc on sc.corporation_id = f.corporation_id where sc.contract_id = b.contract_id and f.year_month = to_char(b.work_date, 'YYYY-MM')) then 'finalized'
      when b.worked_minutes is not null and b.span - b.worked_minutes >= (cfg.c ->> 'deducted_tolerance_minutes')::numeric then 'deducted'
      -- 賃金の種類（2026-11-11 ユーザー指示）: 月給の人だけ。日給の人は対象外。時給だけの人・賃金の登録が無い人も補完しない（その勤務日に有効な賃金で見る）
      when exists (select 1 from employee_wage_settings w where w.user_id = b.user_id and w.division = 1 and w.effective_date <= b.work_date
                     and not exists (select 1 from employee_wage_settings w2 where w2.user_id = w.user_id and w2.contract_id = w.contract_id and w2.division = 1 and w2.effective_date <= b.work_date and w2.effective_date > w.effective_date)) then 'daily_wage'
      when not exists (select 1 from employee_wage_settings w where w.user_id = b.user_id and w.division = 2 and w.effective_date <= b.work_date) then 'not_monthly'
      end reason) r
$$;

-- ============ 4. 同期の記録（Edge Function だけが呼ぶ） ============
-- 始める: 条件をもう一度確かめて、履歴の行を作る（同じ勤怠では 1 回だけ）。補完しないと決めたとき（p_status='skipped'/'conflict'）もここで記録する
create or replace function attendance_break_autofill_begin(p_labor uuid, p_est_start timestamptz, p_est_end timestamptz, p_rule jsonb, p_status text default 'syncing', p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s record; l labor_cost_daily%rowtype; v_id uuid; v_max int := (attendance_break_autofill_cfg() ->> 'max_attempts')::int;
begin
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  if p_status not in ('syncing', 'skipped', 'conflict') then raise exception '不正な状態です'; end if;
  select * into l from labor_cost_daily where id = p_labor for update;
  if l.id is null then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  select * into s from attendance_break_autofill_scan(l.work_date, l.work_date) x where x.labor_cost_daily_id = p_labor;
  if s.labor_cost_daily_id is null then return jsonb_build_object('ok', false, 'reason', 'not_target'); end if;    -- 休憩が入った・短い・対象外の人 など
  if not s.eligible then return jsonb_build_object('ok', false, 'reason', s.skip_reason); end if;
  if p_status = 'syncing' and (p_est_start is null or p_est_end is null or p_est_start < l.clock_in or p_est_end > l.clock_out or p_est_end <= p_est_start) then raise exception '推定の休憩が勤務時間の外です'; end if;
  insert into attendance_break_autofills(labor_cost_daily_id, smaregi_shift_result_id, contract_id, user_id, store_id, work_date, before, est_break_start, est_break_end, est_minutes, rule, status, reason)
  values (p_labor, l.smaregi_shift_result_id, s.contract_id, l.user_id, l.store_id, l.work_date,
          jsonb_build_object('clock_in', l.clock_in, 'clock_out', l.clock_out, 'worked_minutes', l.worked_minutes, 'smaregi_estimate_cost_set', l.smaregi_estimate_cost is not null, 'break_minutes', l.break_minutes),
          p_est_start, p_est_end, case when p_est_start is not null then round(extract(epoch from (p_est_end - p_est_start)) / 60)::int end, p_rule, p_status, p_reason)
  on conflict (labor_cost_daily_id) do update set status = excluded.status, reason = excluded.reason, est_break_start = excluded.est_break_start, est_break_end = excluded.est_break_end, est_minutes = excluded.est_minutes,
       rule = excluded.rule, attempts = attendance_break_autofills.attempts + 1, updated_at = now()
     where attendance_break_autofills.status = 'error' and attendance_break_autofills.attempts < v_max
  returning id into v_id;
  if v_id is null then return jsonb_build_object('ok', false, 'reason', 'already'); end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- 終える: 成功なら、管理システムの勤怠にも同じ休憩を入れる（スマレジの読み直しの勤務時間・概算人件費を使う＝次の取り込みと同じ値になり、「スマレジ側で直された」という検知が出ない）
create or replace function attendance_break_autofill_finish(p_id uuid, p_status text, p_reason text default null, p_response jsonb default null, p_duty_minute numeric default null, p_cost numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a attendance_break_autofills%rowtype; l labor_cost_daily%rowtype;
begin
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  if p_status not in ('synced', 'error', 'conflict', 'skipped') then raise exception '不正な状態です'; end if;
  select * into a from attendance_break_autofills where id = p_id for update;
  if a.id is null then raise exception '履歴が見つかりません'; end if;
  if a.status <> 'syncing' then return jsonb_build_object('ok', false, 'reason', 'not_syncing', 'status', a.status); end if;
  if p_status = 'synced' then
    select * into l from labor_cost_daily where id = a.labor_cost_daily_id for update;
    if l.id is null or l.break_start_1 is not null or l.break_end_1 is not null or l.break_start_2 is not null or l.manual_fixed_at is not null
       or l.clock_in is distinct from (a.before ->> 'clock_in')::timestamptz or l.clock_out is distinct from (a.before ->> 'clock_out')::timestamptz then
      -- スマレジには入ったが、そのあいだに管理システム側の勤怠が変わっていた: 管理システムは書き換えない（次の取り込みに任せる）
      update attendance_break_autofills set status = 'conflict', reason = 'hub_changed', smaregi_response = p_response, synced_at = now(), updated_at = now() where id = a.id;
      return jsonb_build_object('ok', true, 'status', 'conflict', 'reason', 'hub_changed');
    end if;
    update labor_cost_daily set break_start_1 = a.est_break_start, break_end_1 = a.est_break_end, break_minutes = a.est_minutes,
           worked_minutes = coalesce(p_duty_minute, worked_minutes - a.est_minutes), smaregi_estimate_cost = coalesce(p_cost, smaregi_estimate_cost), updated_at = now()
     where id = l.id;
  end if;
  update attendance_break_autofills set status = p_status, reason = p_reason, smaregi_response = p_response, synced_at = case when p_status = 'synced' then now() else synced_at end, updated_at = now() where id = a.id;
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;

-- 置き換えの検知: 「同期済み（推定）」の勤怠で、いまの休憩が推定と違う・勤怠が消えた → あとから直された（実際の時刻が入った）として記録する
create or replace function attendance_break_autofill_reconcile()
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not (onboarding_is_service() or hq_can_manage()) then raise exception '権限がありません'; end if;
  -- 途中で止まった同期（30 分たっても「同期の途中」のまま）は、失敗として扱う（再試行の対象。スマレジに入っていた場合は、次の取り込みで休憩が入り、対象から外れる）
  update attendance_break_autofills set status = 'error', reason = 'interrupted', updated_at = now() where status = 'syncing' and updated_at < now() - interval '30 minutes';
  update attendance_break_autofills a set status = 'superseded', superseded_at = now(), updated_at = now(),
         reason = case when l.id is null then 'record_deleted' when l.manual_fixed_at is not null then 'fixed_by_request' else 'changed_in_smaregi' end
    from attendance_break_autofills a2 left join labor_cost_daily l on l.id = a2.labor_cost_daily_id
   where a.id = a2.id and a.status = 'synced'
     and (l.id is null or l.break_start_1 is distinct from a.est_break_start or l.break_end_1 is distinct from a.est_break_end or l.break_start_2 is not null);
  get diagnostics n = row_count;
  return n;
end $$;

-- その勤怠の休憩の出どころ: estimated＝自動補完の推定値／recorded＝打刻・修正・スマレジで登録された実際の値／none＝休憩なし
create or replace function attendance_break_source(p_labor uuid) returns text language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from attendance_break_autofills a join labor_cost_daily l on l.id = a.labor_cost_daily_id
                  where a.labor_cost_daily_id = p_labor and a.status = 'synced' and l.break_start_1 = a.est_break_start and l.break_end_1 = a.est_break_end and l.break_start_2 is null) then 'estimated'
    when exists (select 1 from labor_cost_daily l where l.id = p_labor and (l.break_start_1 is not null or coalesce(l.break_minutes, 0) > 0)) then 'recorded'
    else 'none' end
$$;

-- ============ 5. 例外の申告（受け口の Edge Function が呼ぶ。操作者は p_actor） ============
create or replace function sf_break_exception_submit(p_user uuid, p_work_date date, p_kind text, p_minutes integer, p_reason text, p_actor uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_today date := (now() at time zone 'Asia/Tokyo')::date; v_auto boolean;
begin
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  if p_actor is null or not exists (select 1 from users where id = p_actor and is_active) then raise exception '操作者が特定できません'; end if;
  if not exists (select 1 from users where id = p_user and is_active) then raise exception '従業員が見つかりません'; end if;
  -- 本人か、その人の店舗を管理できる人だけ
  if p_actor <> p_user and not exists (select 1 from user_stores us where us.user_id = p_user and sf_can_manage_as(p_actor, us.store_id)) then raise exception 'この人の申告をする権限がありません'; end if;
  if p_kind not in ('none', 'short') then raise exception '申告の種類が不正です'; end if;
  if p_kind = 'short' and (p_minutes is null or p_minutes < 1 or p_minutes > 59) then raise exception '短かった休憩の分数は 1〜59 で入力してください'; end if;
  if p_work_date is null or p_work_date > v_today or p_work_date < v_today - 35 then raise exception '勤務日は、今日から 35 日前までの日付にしてください'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 1 or length(p_reason) > 300 then raise exception '理由を入力してください（300 文字まで）'; end if;
  if exists (select 1 from attendance_break_exceptions where user_id = p_user and work_date = p_work_date and cancelled_at is null) then raise exception 'この日の申告は、すでに出ています'; end if;
  insert into attendance_break_exceptions(user_id, work_date, kind, minutes, reason, declared_by) values (p_user, p_work_date, p_kind, case when p_kind = 'short' then p_minutes end, btrim(p_reason), p_actor) returning id into v_id;
  v_auto := exists (select 1 from attendance_break_autofills a where a.user_id = p_user and a.work_date = p_work_date and a.status in ('syncing', 'synced'));
  return jsonb_build_object('ok', true, 'id', v_id, 'already_autofilled', v_auto,
    'message', case when v_auto then 'この日は、すでに休憩が自動で補完されています。実際の内容に直すには、勤怠修正を申請してください' else '申告を受け付けました。この日は休憩を自動で補完しません' end);
end $$;

-- ============ 6. 本部タスク（同期の失敗・競合・例外だけ。通常の補完は載せない） ============
create or replace function attendance_break_autofill_task_sync()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_max int := (attendance_break_autofill_cfg() ->> 'max_attempts')::int; v_lines text; v_n int; v_task uuid; v_key text := 'break_autofill:' || to_char((now() at time zone 'Asia/Tokyo')::date, 'YYYY-MM-DD');
begin
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  select count(*), string_agg('・' || coalesce(u.name, '—') || 'さん ' || to_char(a.work_date, 'MM/DD') || '（' || coalesce(st.name, '—') || '）: ' ||
           case a.status when 'error' then '同期の失敗' when 'conflict' then '競合（スマレジ側が変わっていた）' else '補完していない' end ||
           coalesce('／' || case a.reason when 'deducted' then 'スマレジ側で休憩が自動で引かれている疑い' when 'night_only' then '深夜を避けて休憩を置けない' when 'closed' then 'スマレジの勤怠が締め済み'
                                 when 'time_changed' then 'スマレジで出勤・退勤が変更されている' when 'not_found' then 'スマレジに勤怠が無い' when 'hub_changed' then '管理システム側の勤怠が変わっていた'
                                 when 'verify_failed' then '書き込んだあとの読み直しが一致しない' else left(a.reason, 60) end, ''), E'\n' order by a.work_date, u.name)
    into v_n, v_lines
    from attendance_break_autofills a left join users u on u.id = a.user_id left join stores st on st.id = a.store_id
   where a.task_noted_at is null and ((a.status = 'error' and a.attempts >= v_max) or a.status = 'conflict' or (a.status = 'skipped' and a.reason in ('deducted', 'night_only', 'closed')));
  if coalesce(v_n, 0) = 0 then return jsonb_build_object('ok', true, 'issues', 0); end if;
  select id into v_task from hq_tasks where exception_key = v_key and deleted_at is null limit 1;
  if v_task is null then
    insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, exception_key)
    values ('【休憩の自動補完】確認が必要な勤怠があります（' || v_n || ' 件）', 'トーホー', 'once', current_date, current_date + 3, '',
            '社員・店長の休憩の自動補完で、自動では処理できなかった勤怠です。勤怠修正のフォームで、実際の休憩を登録してください。' || E'\n' || v_lines, 'members', v_key)
    returning id into v_task;
    insert into hq_task_steps(task_id, title, sort_order, kind, due_date) values (v_task, '対象の勤怠を確認して、必要なら勤怠修正を申請する', 10, 'step', current_date + 3);
    insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, null, 'create', '休憩の自動補完で確認が必要な勤怠があるため自動作成');
  else
    update hq_tasks set description = description || E'\n' || v_lines, updated_at = now() where id = v_task;
    insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, null, 'comment', '確認が必要な勤怠が ' || v_n || ' 件増えました');
  end if;
  update attendance_break_autofills a set task_noted_at = now() where a.task_noted_at is null and ((a.status = 'error' and a.attempts >= v_max) or a.status = 'conflict' or (a.status = 'skipped' and a.reason in ('deducted', 'night_only', 'closed')));
  return jsonb_build_object('ok', true, 'issues', v_n, 'task_id', v_task);
end $$;

-- ============ 7. 状況（本部の画面・確認用。件数だけ。氏名は返さない） ============
create or replace function hr_break_autofill_status(p_days integer default 14)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_from date := (now() at time zone 'Asia/Tokyo')::date - greatest(1, least(coalesce(p_days, 14), 60));
begin
  if not (hq_can_manage() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  return jsonb_build_object('config', attendance_break_autofill_cfg(), 'from', v_from,
    'scan', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select coalesce(s.skip_reason, 'eligible') k, count(*) n from attendance_break_autofill_scan(v_from, null) s group by 1) x),
    'history', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (select a.status || coalesce(':' || a.reason, '') k, count(*) n from attendance_break_autofills a where a.work_date >= v_from group by 1) x),
    'exceptions', (select count(*) from attendance_break_exceptions e where e.work_date >= v_from and e.cancelled_at is null));
end $$;

revoke all on function attendance_break_autofill_cfg(), attendance_break_autofill_scan(date, date), attendance_break_autofill_begin(uuid, timestamptz, timestamptz, jsonb, text, text),
  attendance_break_autofill_finish(uuid, text, text, jsonb, numeric, numeric), attendance_break_autofill_reconcile(), attendance_break_source(uuid), sf_break_exception_submit(uuid, date, text, integer, text, uuid),
  attendance_break_autofill_task_sync(), hr_break_autofill_status(integer) from public, anon, authenticated;
grant execute on function attendance_break_autofill_cfg(), attendance_break_autofill_scan(date, date), attendance_break_autofill_begin(uuid, timestamptz, timestamptz, jsonb, text, text),
  attendance_break_autofill_finish(uuid, text, text, jsonb, numeric, numeric), attendance_break_autofill_reconcile(), sf_break_exception_submit(uuid, date, text, integer, text, uuid), attendance_break_autofill_task_sync() to service_role;
grant execute on function attendance_break_source(uuid), hr_break_autofill_status(integer) to authenticated, service_role;
