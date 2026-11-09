-- =============================================================
-- 2026-11-10 入社登録ワークフロー Phase 2（交通費）・Phase 3（Playwright ジョブ）・Phase 4 の土台（入社中止）の DB
--   前提: 2026-11-09_onboarding_phase1.sql 適用済み。★本番未適用（ユーザー承認後に apply_sql.py）。適用しただけでは挙動は変わらない（EF・Mac 側が使い始めるまで空のまま）
--   承認条件（2026-11-09）の反映:
--     ③ ジョブは DB で永続管理・Mac 停止でも消えない・再起動後に安全に再実行・二重登録防止・保存後 GET 照合・画面変更/認証切れ/保存失敗の検知・一定回数失敗で本部へ通知
--     ② 交通費の判定基準は「仮」（app_settings.commute_rules で数値変更可。20〜30 人分の比較後に正式決定）。最安だけで自動否認しない。本人申請額（片道）と照合
--   個人情報: 住所は employee_profiles にしかない（ここには駅名・経路・運賃だけ）
-- =============================================================

-- -------------------------------------------------------------
-- 0) 設定（数値は画面/SQL で変更可）
-- -------------------------------------------------------------
insert into public.app_settings(key, value)
select 'commute_rules', jsonb_build_object(
  'note', '交通費の自動判定（仮・2026-11-10）。正式ルールは 20〜30 人分の比較後にユーザーが決める',
  'max_extra_minutes', 15,      -- 最速＋この分数以内を「合理的」の候補にする
  'max_transfers', 2,           -- 乗換回数の上限
  'max_walk_m', 1500,           -- 徒歩合計の上限（m）
  'tolerance_yen', 100,         -- 申請額 ≦ 候補の最高運賃 + この額 なら本部確認待ち（それ以上は本人確認待ち）
  'tolerance_pct', 20,          -- 同上（％。どちらか大きい方）
  'al_cap_yen', 6000,           -- AL の上限（単位は cap_unit。スマレジ仕様の確認まで unknown）
  'cap_unit', 'unknown',        -- 'month' | 'shift' | 'unknown'
  'smaregi_write_enabled', false, -- ★ スマレジへの交通費書き込み（Mac 自動操作ジョブの作成）を許可するか。実 API・実機の検証が終わるまで false（ユーザー指示 2026-11-10）
  'bus_needs_review', true,     -- バスを含む経路は本部確認待ち
  'night_needs_review', true    -- 深夜（終電後）の勤務が多い店舗は本部確認待ち（Phase 2 後半）
)
where not exists (select 1 from public.app_settings where key = 'commute_rules');

insert into public.app_settings(key, value)
select 'onboarding_alerts', jsonb_build_object('note', '停滞アラート（Phase 5 で cron 化）', 'stale_hours', 48, 'channel_key', 'hq.jinji', 'repeat_hours', 24, 'quiet_from', 22, 'quiet_to', 8)
where not exists (select 1 from public.app_settings where key = 'onboarding_alerts');

-- -------------------------------------------------------------
-- 1) 既存テーブルへの列追加（採用管理の離脱区分・Phase 4）
-- -------------------------------------------------------------
alter table public.applicants
  add column if not exists exit_stage  text check (exit_stage is null or exit_stage in ('before_interview','interview','after_hire','during_registration','first_shift')),
  add column if not exists exit_reason text check (exit_reason is null or exit_reason in (
    'interview_noshow','declined_before_interview','no_contact_after_hire','dropped_during_registration','first_shift_noshow','declined_before_start','company_reason','other')),
  add column if not exists exit_source text check (exit_source is null or exit_source in ('manual','onboarding','shift')),
  add column if not exists exit_note   text,
  add column if not exists exited_at   timestamptz;
comment on column public.applicants.exit_stage  is '離脱した段階（採用ステータスとは別に保存）: before_interview 面接前 / interview 面接 / after_hire 採用後 / during_registration 入社登録中 / first_shift 初回勤務';
comment on column public.applicants.exit_reason is '離脱理由（バックレ細分化）: interview_noshow 面接無断欠席 / declined_before_interview 面接前辞退 / no_contact_after_hire 採用後連絡不通 / dropped_during_registration 入社登録途中離脱 / first_shift_noshow 初回勤務無断欠勤 / declined_before_start 入社前辞退 / company_reason 会社都合中止 / other';

-- -------------------------------------------------------------
-- 2) 交通費: 本人申請＋経路検索結果（1 人 1 行・最新）
-- -------------------------------------------------------------
create table if not exists public.employee_commute (
  user_id             uuid primary key references public.users(id) on delete cascade,
  workflow_id         uuid references public.onboarding_workflows(id) on delete set null,
  method              text check (method is null or method in ('train','bus','train_bus','bike','walk','car','other')),
  home_station        text,                          -- 本人の最寄り駅（employee_profiles.extra["最寄り駅"] のコピー）
  route_text          text,                          -- 本人が書いた経路（任意）
  claimed_oneway_fare integer check (claimed_oneway_fare is null or claimed_oneway_fare >= 0),  -- 本人申請の片道交通費
  uses_bus            boolean,
  special_note        text,
  submitted_at        timestamptz,
  submitted_via       text,                          -- nippo_join / nippo_admin / slack
  -- 経路検索の結果（EF commute-route が書く）
  search_result       jsonb,                         -- { provider, searched_at, store_id, from, to, candidates:[{summary, fare, time_min, transfers, walk_m, uses_bus, teiki1, teiki3, teiki6, raw_index}], reasonable:[...], error }
  computed_oneway_fare integer,
  computed_round_fare  integer,
  computed_teiki1      integer,
  computed_teiki3      integer,
  computed_teiki6      integer,
  judgement           text check (judgement is null or judgement in ('auto_approvable','hq_review','person_review','search_failed','approved','rejected')),
  judgement_reasons   text[] not null default '{}'::text[],
  judged_at           timestamptz,
  person_reply        text,                          -- 本人確認の返答
  person_replied_at   timestamptz,
  approved_fare       integer,                       -- 本部が承認した片道額
  approved_by         uuid,
  approved_at         timestamptz,
  approve_note        text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
alter table public.employee_commute enable row level security;
drop policy if exists employee_commute_read on public.employee_commute;
create policy employee_commute_read on public.employee_commute for select to authenticated using (public.hq_can_manage() or user_id = auth.uid());

-- 交通費の確定値（スマレジに入れる値の履歴。1 回の設定＝1 行）
create table if not exists public.employee_commute_settings (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.users(id) on delete cascade,
  workflow_id     uuid references public.onboarding_workflows(id) on delete set null,
  contract_id     text not null,
  pay_type        text not null check (pay_type in ('per_shift','per_day','monthly')),   -- 勤務回数ごと / 勤務日数ごと / 月額
  effective_date  date not null,
  scope           text not null default 'all' check (scope in ('all','per_store')),
  amount          integer check (amount is null or amount >= 0),                           -- scope=all のとき
  store_amounts   jsonb,                                                                   -- scope=per_store のとき {store_id: amount}
  cap_amount      integer,                                                                 -- 上限（AL 既定 6000。単位は cap_unit）
  cap_unit        text check (cap_unit is null or cap_unit in ('month','shift','unknown')),
  note            text,
  ui_job_id       uuid,                                                                    -- Playwright ジョブ
  sync_status     text not null default 'pending' check (sync_status in ('pending','queued','synced','error','manual')),
  sync_error      text,
  verified_at     timestamptz,                                                             -- GET で照合できた時刻
  verified_value  jsonb,                                                                   -- GET で読んだ値
  created_by      uuid,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists employee_commute_settings_user_idx on public.employee_commute_settings(user_id, effective_date desc);
alter table public.employee_commute_settings enable row level security;
drop policy if exists employee_commute_settings_read on public.employee_commute_settings;
create policy employee_commute_settings_read on public.employee_commute_settings for select to authenticated using (public.hq_can_manage());

-- 源泉所得税の確定条件
create table if not exists public.employee_tax_settings (
  user_id                 uuid primary key references public.users(id) on delete cascade,
  workflow_id             uuid references public.onboarding_workflows(id) on delete set null,
  tax_category            text not null default 'undetermined' check (tax_category in ('kou','otsu','undetermined')),  -- 甲 / 乙 / 未確定
  dependents_count        integer,
  dependent_form_submitted boolean,
  determined_by           uuid,
  determined_at           timestamptz,
  ui_job_id               uuid,
  sync_status             text not null default 'pending' check (sync_status in ('pending','queued','synced','error','manual')),
  sync_error              text,
  verified_at             timestamptz,
  verified_value          jsonb,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
alter table public.employee_tax_settings enable row level security;
drop policy if exists employee_tax_settings_read on public.employee_tax_settings;
create policy employee_tax_settings_read on public.employee_tax_settings for select to authenticated using (public.hq_can_manage());

-- -------------------------------------------------------------
-- 3) Playwright ジョブ（Mac mini ns-daily-import がポーリング）
-- -------------------------------------------------------------
create table if not exists public.ui_automation_jobs (
  id               uuid primary key default gen_random_uuid(),
  kind             text not null check (kind in ('smaregi_commute','smaregi_tax','smaregi_payslip','smaregi_email','smaregi_read')),  -- smaregi_read=読むだけ（dry-run・立会い用）
  workflow_id      uuid references public.onboarding_workflows(id) on delete set null,
  item_key         text,                                   -- 対応する onboarding_items.item_key（commute_set / withholding_tax / web_payslip / email）
  user_id          uuid references public.users(id) on delete set null,
  contract_id      text,
  smaregi_staff_id text not null,                          -- 操作対象は必ず従業員 ID で特定（氏名検索はしない）
  payload          jsonb not null default '{}'::jsonb,     -- 入れる値（kind ごと）。個人情報は最小限
  dry_run          boolean not null default false,         -- true=画面を開いて現在値を読むだけ・保存しない
  status           text not null default 'pending' check (status in ('pending','claimed','running','success','failed','cancelled')),
  attempts         integer not null default 0,
  max_attempts     integer not null default 3,
  next_retry_at    timestamptz,
  claimed_at       timestamptz,
  claimed_by       text,                                   -- worker 名（ホスト名）
  heartbeat_at     timestamptz,                            -- 実行中の生存確認（30 分途切れたら取り直し可）
  started_at       timestamptz,
  finished_at      timestamptz,
  result           jsonb,                                  -- 保存後に画面/GET で読んだ値・ログの要約
  error            text,
  error_kind       text check (error_kind is null or error_kind in ('auth_expired','screen_changed','save_failed','verify_mismatch','timeout','not_found','other')),
  screenshot_path  text,                                   -- Mac 内のパス（Slack には出さない）
  requested_by     uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
-- 二重実行防止: 同じ人×同じ種類の「未完了」ジョブは 1 つだけ
create unique index if not exists ui_automation_jobs_active_uq on public.ui_automation_jobs(smaregi_staff_id, contract_id, kind) where status in ('pending','claimed','running');
create index if not exists ui_automation_jobs_status_idx on public.ui_automation_jobs(status, next_retry_at, created_at);
alter table public.ui_automation_jobs enable row level security;
drop policy if exists ui_automation_jobs_read on public.ui_automation_jobs;
create policy ui_automation_jobs_read on public.ui_automation_jobs for select to authenticated using (public.hq_can_manage());

create table if not exists public.ui_automation_job_log (
  id         bigserial primary key,
  job_id     uuid not null references public.ui_automation_jobs(id) on delete cascade,
  at         timestamptz not null default now(),
  level      text not null default 'info',
  message    text not null                                 -- 個人情報を含めない（従業員 ID・画面名・結果だけ）
);
alter table public.ui_automation_job_log enable row level security;
drop policy if exists ui_automation_job_log_read on public.ui_automation_job_log;
create policy ui_automation_job_log_read on public.ui_automation_job_log for select to authenticated using (public.hq_can_manage());

-- -------------------------------------------------------------
-- 4) RPC: 通勤情報の保存（本人＝入社フォーム直後 / 本部＝nippo 従業員ページ / Slack）
-- -------------------------------------------------------------
create or replace function public.onboarding_save_commute(
  p_user uuid, p_method text, p_route_text text, p_claimed_fare integer, p_uses_bus boolean, p_note text, p_via text default 'nippo_join', p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
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
    judgement = case when employee_commute.judgement = 'approved' then 'approved' else null end, judgement_reasons = '{}'::text[], judged_at = null,
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
end $$;
grant execute on function public.onboarding_save_commute(uuid, text, text, integer, boolean, text, text, uuid) to authenticated, service_role;

-- 本部の承認（片道額の確定）。最安だけで自動否認はしない＝必ず人が押す
create or replace function public.onboarding_commute_decide(p_user uuid, p_decision text, p_fare integer, p_note text default null, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; c employee_commute%rowtype; v_before jsonb;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_decision not in ('approved','rejected','person_review','hq_review') then raise exception '不正な判断です'; end if;
  select * into c from employee_commute where user_id = p_user for update;
  if c.user_id is null then raise exception '通勤情報がありません'; end if;
  if p_decision = 'approved' and (p_fare is null or p_fare < 0) then raise exception '承認する片道額を指定してください'; end if;
  v_before := jsonb_build_object('judgement', c.judgement, 'approved_fare', c.approved_fare);
  update employee_commute set judgement = p_decision,
         approved_fare = case when p_decision = 'approved' then p_fare else approved_fare end,
         approved_by = case when p_decision = 'approved' then v_actor else approved_by end,
         approved_at = case when p_decision = 'approved' then now() else approved_at end,
         approve_note = coalesce(p_note, approve_note), updated_at = now()
   where user_id = p_user;
  if c.workflow_id is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (c.workflow_id, 'commute_check', 'commute.decided', v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, v_before,
            jsonb_build_object('judgement', p_decision, 'approved_fare', p_fare, 'note', p_note));
    if p_decision = 'approved' then
      perform onboarding_set_item(c.workflow_id, 'commute_check', 'completed', jsonb_build_object('approved_fare', p_fare, 'verified', null), v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, null);
    elsif p_decision = 'rejected' then
      perform onboarding_set_item(c.workflow_id, 'commute_check', 'manual_required', jsonb_build_object('rejected', true), v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, coalesce(p_note, '本部が差し戻し'));
    end if;
  end if;
  return jsonb_build_object('ok', true, 'judgement', p_decision, 'approved_fare', p_fare);
end $$;
grant execute on function public.onboarding_commute_decide(uuid, text, integer, text, uuid) to authenticated, service_role;

-- -------------------------------------------------------------
-- 4b) 移行: SQL 未適用の間に nippo が employee_profiles.extra に控えた通勤情報（通勤手段/通勤経路/片道交通費/バス利用/通勤特記）を employee_commute へ。
--     冪等（既に行がある人は触らない）。適用時に全員ぶん 1 回実行し、以後も nippo が extra にだけ書いた場合の保険として呼べる
-- -------------------------------------------------------------
create or replace function public.onboarding_import_commute_from_extra(p_user uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare r record; n int := 0; v_method text; v_fare int; v_wf uuid;
begin
  if not (public.onboarding_is_service() or public.hq_can_manage()) then raise exception '権限がありません'; end if;
  for r in
    select p.user_id, p.extra from employee_profiles p
     where (p_user is null or p.user_id = p_user) and p.extra is not null
       and (p.extra ? '通勤手段' or p.extra ? '片道交通費' or p.extra ? '通勤経路')
       and not exists (select 1 from employee_commute c where c.user_id = p.user_id)
  loop
    v_method := case r.extra ->> '通勤手段' when '電車' then 'train' when '電車＋バス' then 'train_bus' when 'バス' then 'bus' when '自転車' then 'bike' when '徒歩' then 'walk' when '車・バイク' then 'car' when 'その他' then 'other' else null end;
    v_fare := nullif(regexp_replace(coalesce(r.extra ->> '片道交通費', ''), '[^0-9]', '', 'g'), '')::int;
    select id into v_wf from onboarding_workflows where user_id = r.user_id;
    insert into employee_commute(user_id, workflow_id, method, home_station, route_text, claimed_oneway_fare, uses_bus, special_note, submitted_at, submitted_via)
    values (r.user_id, v_wf, v_method, split_part(coalesce(r.extra ->> '最寄り駅', ''), '／', 1), r.extra ->> '通勤経路', v_fare, (r.extra ->> 'バス利用') = 'あり', r.extra ->> '通勤特記', now(), 'extra_import');
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'imported', n);
end $$;
grant execute on function public.onboarding_import_commute_from_extra(uuid) to authenticated, service_role;
-- 適用時に 1 回（service_role の文脈は適用時には無いので、関数内の権限確認を通すため claims を設定して呼ぶ）
do $$ begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform public.onboarding_import_commute_from_extra(null);
end $$;

-- -------------------------------------------------------------
-- 5) RPC: 交通費設定の確定（Slack モーダル / nippo）→ Playwright ジョブを積む
-- -------------------------------------------------------------
create or replace function public.ui_job_enqueue(p_workflow uuid, p_kind text, p_payload jsonb, p_actor uuid default null, p_dry_run boolean default false)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; wf onboarding_workflows%rowtype; v_item text; v_job uuid; v_staff text; v_contract text;
begin
  if auth.uid() is not null then v_actor := public.onboarding_resolve_actor(null);
  elsif public.onboarding_is_service() then v_actor := p_actor;
  else raise exception '認証が必要です'; end if;
  if p_kind not in ('smaregi_commute','smaregi_tax','smaregi_payslip','smaregi_email','smaregi_read') then raise exception '不正なジョブ種類です'; end if;
  -- ★ 安全スイッチ: app_settings.commute_rules.smaregi_write_enabled が true になるまで、書き込みジョブは作らない（読むだけ smaregi_read / dry_run は可）
  if not coalesce(p_dry_run, false) and p_kind <> 'smaregi_read'
     and coalesce((select value ->> 'smaregi_write_enabled' from app_settings where key = 'commute_rules'), 'false') <> 'true' then
    return jsonb_build_object('ok', false, 'disabled', true, 'error', 'スマレジへの自動書き込みはまだ有効化されていません（実機検証後に app_settings.commute_rules.smaregi_write_enabled を true に）');
  end if;
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
  -- 操作対象は従業員 ID で特定（主契約の有効なリンク）
  select l.contract_id, l.smaregi_staff_id into v_contract, v_staff from employee_smaregi_links l
   where l.user_id = wf.user_id and l.effective_to is null order by l.is_primary desc, l.effective_from desc limit 1;
  if v_staff is null then raise exception 'スマレジに登録されていないためジョブを作れません'; end if;
  v_item := case p_kind when 'smaregi_commute' then 'commute_set' when 'smaregi_tax' then 'withholding_tax' when 'smaregi_payslip' then 'web_payslip' when 'smaregi_email' then 'email' else null end;
  begin
    insert into ui_automation_jobs(kind, workflow_id, item_key, user_id, contract_id, smaregi_staff_id, payload, dry_run, requested_by)
    values (p_kind, p_workflow, v_item, wf.user_id, v_contract, v_staff, coalesce(p_payload, '{}'::jsonb), coalesce(p_dry_run, false), v_actor)
    returning id into v_job;
  exception when unique_violation then
    select id into v_job from ui_automation_jobs where smaregi_staff_id = v_staff and contract_id = v_contract and kind = p_kind and status in ('pending','claimed','running') limit 1;
    return jsonb_build_object('ok', true, 'job_id', v_job, 'duplicate', true);
  end;
  insert into ui_automation_job_log(job_id, message) values (v_job, '作成: ' || p_kind || case when coalesce(p_dry_run, false) then '（読むだけ）' else '' end);
  if v_item is not null and not coalesce(p_dry_run, false) then
    perform onboarding_set_item(p_workflow, v_item, 'retry_wait', jsonb_build_object('ui_job_id', v_job, 'queued_at', now()), v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, null);
  end if;
  insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, payload) values (p_workflow, v_item, 'ui_job.enqueued', v_actor, 'auto', jsonb_build_object('job_id', v_job, 'kind', p_kind, 'dry_run', p_dry_run));
  return jsonb_build_object('ok', true, 'job_id', v_job, 'duplicate', false);
end $$;
grant execute on function public.ui_job_enqueue(uuid, text, jsonb, uuid, boolean) to authenticated, service_role;

-- 交通費設定の確定（履歴に 1 行）＋ジョブ
create or replace function public.onboarding_set_commute_setting(
  p_workflow uuid, p_contract text, p_pay_type text, p_effective_date date, p_scope text, p_amount integer, p_store_amounts jsonb, p_cap_amount integer, p_cap_unit text, p_note text, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; wf onboarding_workflows%rowtype; v_id uuid; v_job jsonb; v_payload jsonb;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
  if p_pay_type not in ('per_shift','per_day','monthly') then raise exception '支給形態が不正です'; end if;
  if p_scope not in ('all','per_store') then raise exception '適用事業所の区分が不正です'; end if;
  if p_scope = 'all' and (p_amount is null or p_amount < 0) then raise exception '金額を指定してください'; end if;
  if p_scope = 'per_store' and (p_store_amounts is null or p_store_amounts = '{}'::jsonb) then raise exception '事業所ごとの金額を指定してください'; end if;
  if p_effective_date is null then raise exception '適用開始日を指定してください'; end if;
  update employee_commute_settings set sync_status = case when sync_status in ('pending','queued') then 'manual' else sync_status end, updated_at = now()
   where user_id = wf.user_id and contract_id = p_contract and sync_status in ('pending','queued');   -- 未反映の古い指示は取り下げ
  insert into employee_commute_settings(user_id, workflow_id, contract_id, pay_type, effective_date, scope, amount, store_amounts, cap_amount, cap_unit, note, sync_status, created_by)
  values (wf.user_id, p_workflow, p_contract, p_pay_type, p_effective_date, p_scope, p_amount, p_store_amounts, p_cap_amount, coalesce(p_cap_unit, 'unknown'), p_note, 'pending', v_actor)
  returning id into v_id;
  v_payload := jsonb_build_object('setting_id', v_id, 'pay_type', p_pay_type, 'effective_date', p_effective_date, 'scope', p_scope, 'amount', p_amount, 'store_amounts', p_store_amounts, 'cap_amount', p_cap_amount, 'cap_unit', coalesce(p_cap_unit, 'unknown'));
  v_job := ui_job_enqueue(p_workflow, 'smaregi_commute', v_payload, v_actor, false);
  if coalesce(v_job ->> 'ok', 'false') = 'true' then
    update employee_commute_settings set ui_job_id = (v_job ->> 'job_id')::uuid, sync_status = 'queued', updated_at = now() where id = v_id;
  else
    -- 自動書き込みが未有効化（または作れない）: 確定値は残し、手動で管理画面に入れる（項目は manual_required）
    update employee_commute_settings set sync_status = 'manual', sync_error = v_job ->> 'error', updated_at = now() where id = v_id;
    perform onboarding_set_item(p_workflow, 'commute_set', 'manual_required', v_payload || jsonb_build_object('manual', true), v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, coalesce(v_job ->> 'error', '自動反映なし'));
  end if;
  insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, after) values (p_workflow, 'commute_set', 'commute.setting_saved', v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, v_payload);
  return jsonb_build_object('ok', true, 'setting_id', v_id, 'job', v_job);
end $$;
grant execute on function public.onboarding_set_commute_setting(uuid, text, text, date, text, integer, jsonb, integer, text, text, uuid) to authenticated, service_role;

-- -------------------------------------------------------------
-- 6) RPC: Mac（Playwright）側の取得・完了。service_role のみ
-- -------------------------------------------------------------
-- 取得: pending（next_retry_at が過ぎたもの）を 1 件、作成順に。heartbeat が 30 分以上途切れた running/claimed は Mac 停止とみなして取り直す（再実行は dry_run と同じく「保存前に現在値を確認」するので安全）
create or replace function public.ui_job_claim(p_worker text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare j ui_automation_jobs%rowtype;
begin
  if not public.onboarding_is_service() then raise exception 'service_role のみ'; end if;
  -- 途切れたジョブの回収
  update ui_automation_jobs set status = 'pending', next_retry_at = now(), updated_at = now()
   where status in ('claimed','running') and coalesce(heartbeat_at, claimed_at, created_at) < now() - interval '30 minutes';
  select * into j from ui_automation_jobs
   where status = 'pending' and (next_retry_at is null or next_retry_at <= now())
   order by created_at for update skip locked limit 1;
  if j.id is null then return jsonb_build_object('ok', true, 'job', null); end if;
  update ui_automation_jobs set status = 'claimed', claimed_at = now(), claimed_by = p_worker, heartbeat_at = now(), attempts = attempts + 1, updated_at = now() where id = j.id returning * into j;
  insert into ui_automation_job_log(job_id, message) values (j.id, '取得: ' || coalesce(p_worker, '?') || '（試行 ' || j.attempts || '/' || j.max_attempts || '）');
  if j.item_key is not null and j.workflow_id is not null and not j.dry_run then
    perform onboarding_set_item(j.workflow_id, j.item_key, 'running', jsonb_build_object('ui_job_id', j.id, 'attempt', j.attempts), null, 'auto', null);
  end if;
  return jsonb_build_object('ok', true, 'job', to_jsonb(j));
end $$;
revoke all on function public.ui_job_claim(text) from public, anon, authenticated;
grant execute on function public.ui_job_claim(text) to service_role;

create or replace function public.ui_job_heartbeat(p_job uuid, p_message text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.onboarding_is_service() then raise exception 'service_role のみ'; end if;
  update ui_automation_jobs set heartbeat_at = now(), status = case when status = 'claimed' then 'running' else status end, started_at = coalesce(started_at, now()), updated_at = now() where id = p_job;
  if p_message is not null then insert into ui_automation_job_log(job_id, message) values (p_job, left(p_message, 500)); end if;
end $$;
revoke all on function public.ui_job_heartbeat(uuid, text) from public, anon, authenticated;
grant execute on function public.ui_job_heartbeat(uuid, text) to service_role;

-- 完了: 成功＝項目 completed（verified は呼び出し側が GET 照合して渡す）／失敗＝回数内なら pending に戻す（次回は next_retry_at 後）、上限なら failed＋項目 manual_required
create or replace function public.ui_job_finish(p_job uuid, p_ok boolean, p_result jsonb default null, p_error text default null, p_error_kind text default null, p_screenshot text default null, p_verified boolean default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare j ui_automation_jobs%rowtype; v_final boolean; v_state text;
begin
  if not public.onboarding_is_service() then raise exception 'service_role のみ'; end if;
  select * into j from ui_automation_jobs where id = p_job for update;
  if j.id is null then return jsonb_build_object('ok', false, 'error', 'ジョブが見つかりません'); end if;
  if p_ok then
    update ui_automation_jobs set status = 'success', finished_at = now(), result = p_result, error = null, error_kind = null, screenshot_path = coalesce(p_screenshot, screenshot_path), updated_at = now() where id = j.id;
    insert into ui_automation_job_log(job_id, message) values (j.id, '成功' || case when p_verified then '（GET 照合一致）' when p_verified = false then '（GET 照合で不一致）' else '（照合なし）' end);
    if j.dry_run then return jsonb_build_object('ok', true, 'status', 'success', 'dry_run', true); end if;
    -- 反映先の表
    if j.kind = 'smaregi_commute' then
      update employee_commute_settings set sync_status = case when p_verified = false then 'error' else 'synced' end, sync_error = case when p_verified = false then '保存後の照合で不一致' else null end,
             verified_at = case when p_verified then now() else null end, verified_value = p_result, updated_at = now() where ui_job_id = j.id;
    elsif j.kind = 'smaregi_tax' then
      update employee_tax_settings set sync_status = case when p_verified = false then 'error' else 'synced' end, sync_error = case when p_verified = false then '保存後の照合で不一致' else null end,
             verified_at = case when p_verified then now() else null end, verified_value = p_result, updated_at = now() where ui_job_id = j.id;
    end if;
    if j.item_key is not null and j.workflow_id is not null then
      v_state := case when p_verified = false then 'failed' else 'completed' end;
      perform onboarding_set_item(j.workflow_id, j.item_key, v_state, jsonb_build_object('ui_job_id', j.id, 'verified', p_verified, 'result', p_result), null, 'auto',
                                  case when p_verified = false then '保存後の照合で不一致（スマレジの値が指示と違う）' else null end);
    end if;
    return jsonb_build_object('ok', true, 'status', 'success', 'item_state', v_state);
  end if;
  -- 失敗
  v_final := j.attempts >= j.max_attempts or p_error_kind in ('auth_expired','screen_changed');   -- 認証切れ・画面変更は再試行しても同じ→すぐ人へ
  update ui_automation_jobs set
    status = case when v_final then 'failed' else 'pending' end,
    next_retry_at = case when v_final then null else now() + (interval '10 minutes' * j.attempts) end,
    finished_at = case when v_final then now() else null end,
    error = left(p_error, 800), error_kind = p_error_kind, screenshot_path = coalesce(p_screenshot, screenshot_path), result = coalesce(p_result, result), updated_at = now()
  where id = j.id;
  insert into ui_automation_job_log(job_id, level, message) values (j.id, 'error', (case when v_final then '失敗（打ち切り）: ' else '失敗（再試行待ち）: ' end) || coalesce(p_error_kind, 'other') || ' ' || left(coalesce(p_error, ''), 300));
  if j.item_key is not null and j.workflow_id is not null and not j.dry_run then
    perform onboarding_set_item(j.workflow_id, j.item_key, case when v_final then 'manual_required' else 'retry_wait' end,
                                jsonb_build_object('ui_job_id', j.id, 'attempt', j.attempts, 'error_kind', p_error_kind), null, 'auto', left(p_error, 300));
  end if;
  if v_final and j.kind = 'smaregi_commute' then update employee_commute_settings set sync_status = 'error', sync_error = left(p_error, 300), updated_at = now() where ui_job_id = j.id; end if;
  if v_final and j.kind = 'smaregi_tax' then update employee_tax_settings set sync_status = 'error', sync_error = left(p_error, 300), updated_at = now() where ui_job_id = j.id; end if;
  return jsonb_build_object('ok', true, 'status', case when v_final then 'failed' else 'pending' end, 'final', v_final, 'attempts', j.attempts);
end $$;
revoke all on function public.ui_job_finish(uuid, boolean, jsonb, text, text, text, boolean) from public, anon, authenticated;
grant execute on function public.ui_job_finish(uuid, boolean, jsonb, text, text, text, boolean) to service_role;

-- 手動対応が必要になったとき、本部タスクに工程を足す（hq_add_onboarding_affiliation_step と同じ作法。重複しない）
create or replace function public.onboarding_add_manual_step(p_workflow uuid, p_title text, p_reason text default null)
returns uuid
language plpgsql security definer set search_path to 'public'
as $$
declare wf onboarding_workflows%rowtype; v_step uuid; v_assignee uuid; v_due date;
begin
  if not (public.onboarding_is_service() or public.hq_can_manage()) then raise exception '権限がありません'; end if;
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null or wf.hq_task_id is null then return null; end if;
  select id into v_step from hq_task_steps where task_id = wf.hq_task_id and title = p_title and completed_at is null limit 1;
  if v_step is not null then return v_step; end if;
  select assignee_id, due_date into v_assignee, v_due from hq_task_steps where task_id = wf.hq_task_id and assignee_id is not null order by sort_order limit 1;
  insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date, procedure_note)
  values (wf.hq_task_id, p_title, v_assignee, 35, 'step', v_due, p_reason) returning id into v_step;
  insert into hq_task_activity(task_id, actor_id, kind, detail) values (wf.hq_task_id, null, 'comment', '入社ワークフロー: 手動対応の工程を追加（' || p_title || '）' || coalesce('　理由: ' || p_reason, ''));
  return v_step;
end $$;
revoke all on function public.onboarding_add_manual_step(uuid, text, text) from public, anon;
grant execute on function public.onboarding_add_manual_step(uuid, text, text) to authenticated, service_role;

-- -------------------------------------------------------------
-- 7) Phase 4 の土台: 入社手続き中止（理由 5 区分）。スマレジ従業員は削除しない（利用 OFF は人の判断で別途）
-- -------------------------------------------------------------
create or replace function public.onboarding_cancel(p_workflow uuid, p_reason text, p_note text default null, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; wf onboarding_workflows%rowtype; v_stage text; v_exit text;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_reason not in ('declined_by_person','no_contact_after_hire','dropped_during_registration','company_reason','other') then raise exception '中止理由が不正です'; end if;
  select * into wf from onboarding_workflows where id = p_workflow for update;
  if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
  if wf.status = 'cancelled' then return jsonb_build_object('ok', true, 'already', true); end if;
  update onboarding_workflows set status = 'cancelled', cancelled_reason = p_reason, cancel_note = p_note, cancelled_at = now(), cancelled_by = v_actor, updated_at = now() where id = p_workflow;
  update onboarding_items set state = 'cancelled', updated_at = now() where workflow_id = p_workflow and state <> 'completed';
  update ui_automation_jobs set status = 'cancelled', finished_at = now(), updated_at = now() where workflow_id = p_workflow and status in ('pending','claimed');
  -- 採用管理へ: 離脱段階・理由を別々に保存（採用ステータスは変えない）
  if wf.applicant_id is not null then
    v_stage := case when (select count(*) from onboarding_items where workflow_id = p_workflow and item_key = 'join_form' and state = 'completed') > 0 then 'during_registration' else 'after_hire' end;
    v_exit := case p_reason when 'declined_by_person' then 'declined_before_start' when 'no_contact_after_hire' then 'no_contact_after_hire'
                            when 'dropped_during_registration' then 'dropped_during_registration' when 'company_reason' then 'company_reason' else 'other' end;
    update applicants set exit_stage = coalesce(exit_stage, v_stage), exit_reason = coalesce(exit_reason, v_exit), exit_source = coalesce(exit_source, 'onboarding'),
           exit_note = coalesce(exit_note, p_note), exited_at = coalesce(exited_at, now()), updated_at = now() where id = wf.applicant_id;
  end if;
  if wf.hq_task_id is not null then
    insert into hq_task_activity(task_id, actor_id, kind, detail) values (wf.hq_task_id, v_actor, 'comment', '入社手続きを中止（' || p_reason || '）' || coalesce('　' || p_note, '') || '。このタスクは手で完了または削除してください');
  end if;
  insert into onboarding_events(workflow_id, kind, actor_id, via, after) values (p_workflow, 'workflow.cancelled', v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, jsonb_build_object('reason', p_reason, 'note', p_note));
  return jsonb_build_object('ok', true, 'reason', p_reason, 'applicant_id', wf.applicant_id);
end $$;
grant execute on function public.onboarding_cancel(uuid, text, text, uuid) to authenticated, service_role;

-- -------------------------------------------------------------
-- 8) 採用管理の集計ビュー（媒体・店舗・担当者別の離脱区分）
-- -------------------------------------------------------------
create or replace view public.recruit_funnel_v as
select a.source, a.store_id, s.name as store_name, a.assignee_id, u.name as assignee_name,
       date_trunc('month', a.applied_at)::date as applied_month,
       count(*) as applicants,
       count(*) filter (where a.status in ('hired')) as hired,
       count(*) filter (where a.exit_reason = 'interview_noshow') as interview_noshow,
       count(*) filter (where a.exit_reason = 'declined_before_interview') as declined_before_interview,
       count(*) filter (where a.exit_reason = 'no_contact_after_hire') as no_contact_after_hire,
       count(*) filter (where a.exit_reason = 'dropped_during_registration') as dropped_during_registration,
       count(*) filter (where a.exit_reason = 'first_shift_noshow') as first_shift_noshow,
       count(*) filter (where a.exit_reason = 'declined_before_start') as declined_before_start,
       count(*) filter (where a.exit_reason = 'company_reason') as company_reason,
       count(*) filter (where a.exit_reason = 'other') as exit_other
  from applicants a left join stores s on s.id = a.store_id left join users u on u.id = a.assignee_id
 group by a.source, a.store_id, s.name, a.assignee_id, u.name, date_trunc('month', a.applied_at);
alter view public.recruit_funnel_v set (security_invoker = true);
grant select on public.recruit_funnel_v to authenticated, service_role;

-- -------------------------------------------------------------
-- 9) 停滞の一覧（Phase 5 の cron が読む。今はビューだけ）
-- -------------------------------------------------------------
create or replace view public.onboarding_stale_v as
select w.id as workflow_id, w.user_id, u.name as user_name, w.status, w.hire_date, w.updated_at,
       i.item_key, i.state, i.updated_at as item_updated_at, i.last_error,
       extract(epoch from (now() - i.updated_at)) / 3600 as hours_stalled
  from onboarding_workflows w join users u on u.id = w.user_id join onboarding_items i on i.workflow_id = w.id
 where w.status = 'registering' and i.state in ('pending','retry_wait','manual_required','failed');
alter view public.onboarding_stale_v set (security_invoker = true);
grant select on public.onboarding_stale_v to authenticated, service_role;
