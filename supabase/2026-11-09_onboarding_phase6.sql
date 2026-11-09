-- =============================================================
-- 入社登録 Phase 6（2026-11-09・★ 本番未適用。適用は中山さんの承認後）
--   ユーザー要望: ①管理システムの店舗 → スマレジ・タイムカードの事業所を自動作成（API に登録が無いので管理画面の自動操作）
--               ②入社フォームでは扶養家族・年末調整を飛ばし、入社後に本人が別フォームで提出 → 管理システムに保存 → Playwright でスマレジへ。未提出は定期リマインド。Slack で追跡
--               ③源泉所得税の Slack 画面をスマレジと同じ 4 項目に（適用開始月・区分・配偶者区分・親族の数）
--   方針: 入社登録の「完了」は従来の 10 項目のまま（扶養・年末調整は入社後の別トラック＝完了を止めない）。
--         個人情報（氏名・住所・生年月日）は DB の中だけ。Slack には件数・続柄だけ。マイナンバーは預からない。
--   内容（追加のみ。既存の行は書き換えない。既存関数は create or replace で新版に差し替え＝ui_job_enqueue のみ）:
--     1) 表 employee_year_end / employee_dependents（RLS 読み = 本人 or hq_can_manage）
--     2) employee_tax_settings に application_ym / spouse_deduction_division
--     3) ui_automation_jobs.kind に smaregi_year_end / smaregi_dependents / smaregi_store
--     4) ui_job_enqueue 新版（新しい kind・店舗ジョブは workflow 無し）
--     5) RPC: onboarding_save_year_end / onboarding_save_dependents / onboarding_skip_post_join / onboarding_set_tax_setting /
--             onboarding_enqueue_year_end / onboarding_enqueue_dependents / onboarding_post_join_targets /
--             smaregi_store_create_request / smaregi_store_mapping_upsert
--     6) ビュー onboarding_post_join_v・onboarding_workflow_v 新版（year_end / dependents 列を追加）
--     7) app_settings.onboarding_alerts に post_join_remind_* ・cron 用関数（schedule はコメント）
--   切り戻し: supabase/2026-11-09_onboarding_phase6_rollback.sql（データ保全版）
-- =============================================================

-- -------------------------------------------------------------
-- 1) 表
-- -------------------------------------------------------------
create table if not exists public.employee_year_end (
  user_id                                  uuid primary key references public.users(id) on delete cascade,
  workflow_id                              uuid references public.onboarding_workflows(id) on delete set null,
  household_header_name                    text,                       -- 世帯主（32 文字以内）
  household_header_relationship            integer,                    -- 0 本人 … 14 義母 / 99 その他（スマレジと同じ値）
  spouse_flag                              boolean not null default false,
  estimate_income                          integer not null default 0, -- 合計所得見積額（円）
  retirement_income                        integer not null default 0, -- 退職所得（円）
  handicapped_division                     integer not null default 1 check (handicapped_division in (1,2,3)),
  widow_division2                          integer not null default 1 check (widow_division2 in (1,2,3)),
  widow_division                           integer not null default 1 check (widow_division in (1,2,3,4)),
  student_flag                             boolean not null default false,
  salary_payment_report_collection_division integer not null default 1 check (salary_payment_report_collection_division in (1,2)),
  submitted_at                             timestamptz,
  submitted_via                            text,
  confirmed_by                             uuid,
  confirmed_at                             timestamptz,
  ui_job_id                                uuid,
  sync_status                              text not null default 'pending' check (sync_status in ('pending','queued','synced','error','manual','skipped')),
  sync_error                               text,
  verified_at                              timestamptz,
  verified_value                           jsonb,
  created_at                               timestamptz not null default now(),
  updated_at                               timestamptz not null default now()
);
alter table public.employee_year_end enable row level security;
drop policy if exists employee_year_end_read on public.employee_year_end;
create policy employee_year_end_read on public.employee_year_end for select to authenticated using (public.hq_can_manage() or user_id = auth.uid());

create table if not exists public.employee_dependents (
  id                        uuid primary key default gen_random_uuid(),
  user_id                   uuid not null references public.users(id) on delete cascade,
  workflow_id               uuid references public.onboarding_workflows(id) on delete set null,
  name                      text not null,
  kana                      text not null default '',
  relationship              integer not null,                          -- 1 配偶者 … 14 義母 / 99 その他
  birthday                  date,
  living_together_division  integer not null default 1 check (living_together_division in (1,2,3)),  -- 1 同居 / 2 別居(国内) / 3 別居(海外)
  post_code                 text,
  address                   text,
  estimate_income           integer not null default 0,
  retirement_income         integer not null default 0,
  handicapped_division      integer not null default 1 check (handicapped_division in (1,2,3)),
  is_active                 boolean not null default true,
  submitted_at              timestamptz,
  submitted_via             text,
  smaregi_synced_at         timestamptz,
  ui_job_id                 uuid,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);
create index if not exists employee_dependents_user_idx on public.employee_dependents(user_id, is_active);
alter table public.employee_dependents enable row level security;
drop policy if exists employee_dependents_read on public.employee_dependents;
create policy employee_dependents_read on public.employee_dependents for select to authenticated using (public.hq_can_manage() or user_id = auth.uid());

-- 「扶養なし」「年末調整なし（不要）」の提出状態（行が無い人と区別する）
create table if not exists public.employee_post_join_status (
  user_id              uuid primary key references public.users(id) on delete cascade,
  workflow_id          uuid references public.onboarding_workflows(id) on delete set null,
  dependents_status    text not null default 'pending' check (dependents_status in ('pending','submitted','none','synced','skipped')),
  dependents_submitted_at timestamptz,
  year_end_status      text not null default 'pending' check (year_end_status in ('pending','submitted','synced','skipped')),
  year_end_submitted_at timestamptz,
  last_reminded_at     timestamptz,
  remind_count         integer not null default 0,
  updated_at           timestamptz not null default now()
);
alter table public.employee_post_join_status enable row level security;
drop policy if exists employee_post_join_status_read on public.employee_post_join_status;
create policy employee_post_join_status_read on public.employee_post_join_status for select to authenticated using (public.hq_can_manage() or user_id = auth.uid());

-- 2) 源泉所得税の設定に、スマレジの画面と同じ 2 項目
alter table public.employee_tax_settings add column if not exists application_ym text;                       -- 'YYYY-MM'
alter table public.employee_tax_settings add column if not exists spouse_deduction_division integer default 0; -- 0 対象でない / 1 配偶者控除対象 / 2 配偶者特別控除対象

-- 3) ジョブの種類
alter table public.ui_automation_jobs drop constraint if exists ui_automation_jobs_kind_check;
alter table public.ui_automation_jobs add constraint ui_automation_jobs_kind_check
  check (kind in ('smaregi_commute','smaregi_tax','smaregi_payslip','smaregi_email','smaregi_read','smaregi_year_end','smaregi_dependents','smaregi_store'));
alter table public.ui_automation_jobs alter column workflow_id drop not null;

-- -------------------------------------------------------------
-- 4) ui_job_enqueue 新版（互換: 既存 5 種は従来どおり。追加: year_end / dependents は項目無し、store は workflow 無し＝smaregi_staff_id に 'store:<店舗id>'）
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
  if p_kind not in ('smaregi_commute','smaregi_tax','smaregi_payslip','smaregi_email','smaregi_read','smaregi_year_end','smaregi_dependents','smaregi_store') then raise exception '不正なジョブ種類です'; end if;
  -- ★ 安全スイッチ: app_settings.commute_rules.smaregi_write_enabled が true になるまで、書き込みジョブは作らない（読むだけ smaregi_read / dry_run は可）
  if not coalesce(p_dry_run, false) and p_kind <> 'smaregi_read'
     and coalesce((select value ->> 'smaregi_write_enabled' from app_settings where key = 'commute_rules'), 'false') <> 'true' then
    return jsonb_build_object('ok', false, 'disabled', true, 'error', 'スマレジへの自動書き込みはまだ有効化されていません（実機検証後に app_settings.commute_rules.smaregi_write_enabled を true に）');
  end if;
  if p_kind = 'smaregi_store' then
    -- 事業所の作成: 従業員ではなく店舗が対象。payload.store_id / contract_id 必須
    if coalesce(p_payload ->> 'store_id', '') = '' or coalesce(p_payload ->> 'contract_id', '') = '' then raise exception '店舗ジョブには payload.store_id と contract_id が必要です'; end if;
    v_staff := 'store:' || (p_payload ->> 'store_id'); v_contract := p_payload ->> 'contract_id'; v_item := null;
  else
    select * into wf from onboarding_workflows where id = p_workflow;
    if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
    select l.contract_id, l.smaregi_staff_id into v_contract, v_staff from employee_smaregi_links l
     where l.user_id = wf.user_id and l.effective_to is null order by l.is_primary desc, l.effective_from desc limit 1;
    if v_staff is null then raise exception 'スマレジに登録されていないためジョブを作れません'; end if;
    v_item := case p_kind when 'smaregi_commute' then 'commute_set' when 'smaregi_tax' then 'withholding_tax' when 'smaregi_payslip' then 'web_payslip' when 'smaregi_email' then 'email' else null end;
  end if;
  begin
    insert into ui_automation_jobs(kind, workflow_id, item_key, user_id, contract_id, smaregi_staff_id, payload, dry_run, requested_by)
    values (p_kind, case when p_kind = 'smaregi_store' then null else p_workflow end, v_item, wf.user_id, v_contract, v_staff, coalesce(p_payload, '{}'::jsonb), coalesce(p_dry_run, false), v_actor)
    returning id into v_job;
  exception when unique_violation then
    select id into v_job from ui_automation_jobs where smaregi_staff_id = v_staff and contract_id = v_contract and kind = p_kind and status in ('pending','claimed','running') limit 1;
    return jsonb_build_object('ok', true, 'job_id', v_job, 'duplicate', true);
  end;
  insert into ui_automation_job_log(job_id, message) values (v_job, '作成: ' || p_kind || case when coalesce(p_dry_run, false) then '（読むだけ）' else '' end);
  if v_item is not null and not coalesce(p_dry_run, false) then
    perform onboarding_set_item(p_workflow, v_item, 'retry_wait', jsonb_build_object('ui_job_id', v_job, 'queued_at', now()), v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, null);
  end if;
  if p_workflow is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, payload) values (p_workflow, v_item, 'ui_job.enqueued', v_actor, 'auto', jsonb_build_object('job_id', v_job, 'kind', p_kind, 'dry_run', p_dry_run));
  end if;
  return jsonb_build_object('ok', true, 'job_id', v_job, 'duplicate', false);
end $$;
grant execute on function public.ui_job_enqueue(uuid, text, jsonb, uuid, boolean) to authenticated, service_role;

-- -------------------------------------------------------------
-- 5) RPC
-- -------------------------------------------------------------
-- 本人（または本部・service）かどうか
create or replace function public.onboarding_self_or_hq(p_user uuid, p_actor uuid)
returns uuid language plpgsql stable as $$
begin
  if auth.uid() is not null then
    if auth.uid() <> p_user and not exists (select 1 from users x where x.id = auth.uid() and x.is_active and (x.is_master or x.role in ('CEO','HQ'))) then raise exception '権限がありません'; end if;
    return auth.uid();
  elsif public.onboarding_is_service() then return p_actor;
  else raise exception '認証が必要です'; end if;
end $$;
revoke all on function public.onboarding_self_or_hq(uuid, uuid) from public, anon;

-- 年末調整の提出（本人のマイページ / 本部）。p_data はスマレジの列名そのまま
create or replace function public.onboarding_save_year_end(p_user uuid, p_data jsonb, p_via text default 'nippo_self', p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; v_wf uuid; v_before jsonb;
begin
  v_actor := public.onboarding_self_or_hq(p_user, p_actor);
  select id into v_wf from onboarding_workflows where user_id = p_user;
  select to_jsonb(y) into v_before from employee_year_end y where y.user_id = p_user;
  insert into employee_year_end(user_id, workflow_id, household_header_name, household_header_relationship, spouse_flag, estimate_income, retirement_income,
                                handicapped_division, widow_division2, widow_division, student_flag, salary_payment_report_collection_division, submitted_at, submitted_via, sync_status)
  values (p_user, v_wf, left(nullif(trim(coalesce(p_data ->> 'household_header_name', '')), ''), 32), nullif(p_data ->> 'household_header_relationship', '')::int,
          coalesce((p_data ->> 'spouse_flag')::boolean, false), coalesce(nullif(p_data ->> 'estimate_income', '')::int, 0), coalesce(nullif(p_data ->> 'retirement_income', '')::int, 0),
          coalesce(nullif(p_data ->> 'handicapped_division', '')::int, 1), coalesce(nullif(p_data ->> 'widow_division2', '')::int, 1), coalesce(nullif(p_data ->> 'widow_division', '')::int, 1),
          coalesce((p_data ->> 'student_flag')::boolean, false), coalesce(nullif(p_data ->> 'salary_payment_report_collection_division', '')::int, 1), now(), coalesce(p_via, 'nippo_self'), 'pending')
  on conflict (user_id) do update set
    workflow_id = coalesce(employee_year_end.workflow_id, excluded.workflow_id), household_header_name = excluded.household_header_name, household_header_relationship = excluded.household_header_relationship,
    spouse_flag = excluded.spouse_flag, estimate_income = excluded.estimate_income, retirement_income = excluded.retirement_income, handicapped_division = excluded.handicapped_division,
    widow_division2 = excluded.widow_division2, widow_division = excluded.widow_division, student_flag = excluded.student_flag,
    salary_payment_report_collection_division = excluded.salary_payment_report_collection_division, submitted_at = now(), submitted_via = excluded.submitted_via,
    sync_status = case when employee_year_end.sync_status = 'synced' and to_jsonb(excluded) - 'submitted_at' - 'submitted_via' - 'sync_status' - 'updated_at' - 'created_at' - 'workflow_id' - 'ui_job_id' - 'verified_at' - 'verified_value' - 'sync_error' - 'confirmed_by' - 'confirmed_at'
                                                                                        = to_jsonb(employee_year_end) - 'submitted_at' - 'submitted_via' - 'sync_status' - 'updated_at' - 'created_at' - 'workflow_id' - 'ui_job_id' - 'verified_at' - 'verified_value' - 'sync_error' - 'confirmed_by' - 'confirmed_at'
                       then 'synced' else 'pending' end,
    updated_at = now();
  insert into employee_post_join_status(user_id, workflow_id, year_end_status, year_end_submitted_at)
  values (p_user, v_wf, 'submitted', now())
  on conflict (user_id) do update set year_end_status = case when employee_post_join_status.year_end_status = 'synced' and (select sync_status from employee_year_end where user_id = p_user) = 'synced' then 'synced' else 'submitted' end,
                                       year_end_submitted_at = now(), workflow_id = coalesce(employee_post_join_status.workflow_id, excluded.workflow_id), updated_at = now();
  if v_wf is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (v_wf, null, 'year_end.submitted', v_actor, case when auth.uid() is null then 'system' else 'nippo' end,
            case when v_before is null then null else jsonb_build_object('submitted_at', v_before ->> 'submitted_at') end,
            jsonb_build_object('spouse_flag', coalesce((p_data ->> 'spouse_flag')::boolean, false), 'student_flag', coalesce((p_data ->> 'student_flag')::boolean, false), 'via', p_via));
  end if;
  return jsonb_build_object('ok', true, 'workflow_id', v_wf);
end $$;
grant execute on function public.onboarding_save_year_end(uuid, jsonb, text, uuid) to authenticated, service_role;

-- 扶養親族の提出: 今の有効行を全部無効にして p_rows（配列。各要素はスマレジの列名）を入れ直す。0 件＝「扶養なし」
create or replace function public.onboarding_save_dependents(p_user uuid, p_rows jsonb, p_via text default 'nippo_self', p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; v_wf uuid; r jsonb; n int := 0; v_rel int;
begin
  v_actor := public.onboarding_self_or_hq(p_user, p_actor);
  if p_rows is not null and jsonb_typeof(p_rows) <> 'array' then raise exception 'p_rows は配列で渡してください'; end if;
  select id into v_wf from onboarding_workflows where user_id = p_user;
  update employee_dependents set is_active = false, updated_at = now() where user_id = p_user and is_active;
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    if coalesce(trim(r ->> 'name'), '') = '' then raise exception '扶養親族の名前は必須です'; end if;
    v_rel := nullif(r ->> 'relationship', '')::int;
    if v_rel is null or not (v_rel between 1 and 14 or v_rel = 99) then raise exception '続柄が不正です'; end if;
    insert into employee_dependents(user_id, workflow_id, name, kana, relationship, birthday, living_together_division, post_code, address, estimate_income, retirement_income, handicapped_division, submitted_at, submitted_via)
    values (p_user, v_wf, left(trim(r ->> 'name'), 50), left(coalesce(r ->> 'kana', ''), 50), v_rel, nullif(r ->> 'birthday', '')::date,
            coalesce(nullif(r ->> 'living_together_division', '')::int, 1), nullif(r ->> 'post_code', ''), left(coalesce(r ->> 'address', ''), 200),
            coalesce(nullif(r ->> 'estimate_income', '')::int, 0), coalesce(nullif(r ->> 'retirement_income', '')::int, 0), coalesce(nullif(r ->> 'handicapped_division', '')::int, 1), now(), coalesce(p_via, 'nippo_self'));
    n := n + 1;
  end loop;
  insert into employee_post_join_status(user_id, workflow_id, dependents_status, dependents_submitted_at)
  values (p_user, v_wf, case when n = 0 then 'none' else 'submitted' end, now())
  on conflict (user_id) do update set dependents_status = case when n = 0 then 'none' else 'submitted' end, dependents_submitted_at = now(),
                                       workflow_id = coalesce(employee_post_join_status.workflow_id, excluded.workflow_id), updated_at = now();
  -- 源泉所得税の「親族の数」の初期値に使えるよう控える
  update employee_tax_settings set dependents_count = n, dependent_form_submitted = true, updated_at = now() where user_id = p_user;
  if v_wf is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, after)
    values (v_wf, null, 'dependents.submitted', v_actor, case when auth.uid() is null then 'system' else 'nippo' end,
            jsonb_build_object('count', n, 'relationships', (select jsonb_agg(relationship) from employee_dependents where user_id = p_user and is_active), 'via', p_via));
  end if;
  return jsonb_build_object('ok', true, 'workflow_id', v_wf, 'count', n);
end $$;
grant execute on function public.onboarding_save_dependents(uuid, jsonb, text, uuid) to authenticated, service_role;

-- 本部: 「不要」にする（year_end / dependents）
create or replace function public.onboarding_skip_post_join(p_user uuid, p_kind text, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; v_wf uuid;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_kind not in ('year_end', 'dependents') then raise exception '種類が不正です'; end if;
  select id into v_wf from onboarding_workflows where user_id = p_user;
  insert into employee_post_join_status(user_id, workflow_id) values (p_user, v_wf) on conflict (user_id) do nothing;
  if p_kind = 'year_end' then
    update employee_post_join_status set year_end_status = 'skipped', updated_at = now() where user_id = p_user;
    update employee_year_end set sync_status = 'skipped', updated_at = now() where user_id = p_user;
  else
    update employee_post_join_status set dependents_status = 'skipped', updated_at = now() where user_id = p_user;
  end if;
  if v_wf is not null then insert into onboarding_events(workflow_id, kind, actor_id, via, payload) values (v_wf, 'post_join.skipped', v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, jsonb_build_object('kind', p_kind)); end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.onboarding_skip_post_join(uuid, text, uuid) to authenticated, service_role;

-- 源泉所得税の設定（Slack モーダル＝スマレジと同じ 4 項目）→ ジョブ（スイッチ OFF なら manual）
create or replace function public.onboarding_set_tax_setting(p_workflow uuid, p_application_ym text, p_tax_category text, p_spouse_division integer, p_dependents_count integer, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; wf onboarding_workflows%rowtype; v_job jsonb; v_payload jsonb; v_ym text;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
  if p_tax_category not in ('kou', 'otsu') then raise exception '区分は甲か乙です'; end if;
  if coalesce(p_spouse_division, 0) not in (0, 1, 2) then raise exception '配偶者区分が不正です'; end if;
  if coalesce(p_dependents_count, 0) < 0 or coalesce(p_dependents_count, 0) > 20 then raise exception '親族の数が不正です'; end if;
  v_ym := substr(regexp_replace(coalesce(p_application_ym, ''), '/', '-'), 1, 7);
  if v_ym !~ '^\d{4}-\d{2}$' then raise exception '適用開始月は YYYY-MM で指定してください'; end if;
  insert into employee_tax_settings(user_id, workflow_id, tax_category, dependents_count, application_ym, spouse_deduction_division, determined_by, determined_at, sync_status)
  values (wf.user_id, p_workflow, p_tax_category, coalesce(p_dependents_count, 0), v_ym, coalesce(p_spouse_division, 0), v_actor, now(), 'pending')
  on conflict (user_id) do update set workflow_id = coalesce(employee_tax_settings.workflow_id, excluded.workflow_id), tax_category = excluded.tax_category, dependents_count = excluded.dependents_count,
    application_ym = excluded.application_ym, spouse_deduction_division = excluded.spouse_deduction_division, determined_by = excluded.determined_by, determined_at = now(),
    sync_status = 'pending', sync_error = null, updated_at = now();
  v_payload := jsonb_build_object('tax_category', p_tax_category, 'application_ym', v_ym, 'spouse_value', coalesce(p_spouse_division, 0), 'dependents_count', coalesce(p_dependents_count, 0));
  v_job := ui_job_enqueue(p_workflow, 'smaregi_tax', v_payload, v_actor, false);
  if coalesce(v_job ->> 'ok', 'false') = 'true' then
    update employee_tax_settings set ui_job_id = (v_job ->> 'job_id')::uuid, sync_status = 'queued', updated_at = now() where user_id = wf.user_id;
  else
    update employee_tax_settings set sync_status = 'manual', sync_error = v_job ->> 'error', updated_at = now() where user_id = wf.user_id;
    perform onboarding_set_item(p_workflow, 'withholding_tax', 'manual_required', v_payload || jsonb_build_object('manual', true), v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, coalesce(v_job ->> 'error', '自動書き込みが未有効化'));
  end if;
  insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, after) values (p_workflow, 'withholding_tax', 'tax.setting_saved', v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, v_payload || jsonb_build_object('job', v_job));
  return jsonb_build_object('ok', true, 'job', v_job, 'payload', v_payload);
end $$;
grant execute on function public.onboarding_set_tax_setting(uuid, text, text, integer, integer, uuid) to authenticated, service_role;

-- 年末調整をスマレジへ（本部ボタン）: employee_year_end → ジョブ
create or replace function public.onboarding_enqueue_year_end(p_workflow uuid, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; wf onboarding_workflows%rowtype; y employee_year_end%rowtype; v_job jsonb;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into wf from onboarding_workflows where id = p_workflow; if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
  select * into y from employee_year_end where user_id = wf.user_id; if y.user_id is null then return jsonb_build_object('ok', false, 'error', '年末調整の提出がまだありません'); end if;
  v_job := ui_job_enqueue(p_workflow, 'smaregi_year_end', jsonb_build_object(
    'household_header_name', y.household_header_name, 'household_header_relationship', y.household_header_relationship, 'spouse_flag', y.spouse_flag,
    'estimate_income', y.estimate_income, 'retirement_income', y.retirement_income, 'handicapped_division', y.handicapped_division,
    'widow_division2', y.widow_division2, 'widow_division', y.widow_division, 'student_flag', y.student_flag,
    'salary_payment_report_collection_division', y.salary_payment_report_collection_division), v_actor, false);
  if coalesce(v_job ->> 'ok', 'false') = 'true' then
    update employee_year_end set ui_job_id = (v_job ->> 'job_id')::uuid, sync_status = 'queued', confirmed_by = v_actor, confirmed_at = now(), updated_at = now() where user_id = wf.user_id;
  else
    update employee_year_end set sync_status = 'manual', sync_error = v_job ->> 'error', confirmed_by = v_actor, confirmed_at = now(), updated_at = now() where user_id = wf.user_id;
  end if;
  insert into onboarding_events(workflow_id, kind, actor_id, via, payload) values (p_workflow, 'year_end.enqueued', v_actor, 'slack', v_job);
  return jsonb_build_object('ok', true, 'job', v_job);
end $$;
grant execute on function public.onboarding_enqueue_year_end(uuid, uuid) to authenticated, service_role;

-- 扶養親族をスマレジへ（本部ボタン）: 有効行の配列 → ジョブ（名前・住所は DB とジョブの中だけ。Slack には出さない）
create or replace function public.onboarding_enqueue_dependents(p_workflow uuid, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; wf onboarding_workflows%rowtype; v_rows jsonb; v_job jsonb;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into wf from onboarding_workflows where id = p_workflow; if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'kana', d.kana, 'relationship', d.relationship, 'birthday', d.birthday, 'living_together_division', d.living_together_division,
                                               'post_code', d.post_code, 'address', d.address, 'estimate_income', d.estimate_income, 'retirement_income', d.retirement_income, 'handicapped_division', d.handicapped_division) order by d.created_at), '[]'::jsonb)
    into v_rows from employee_dependents d where d.user_id = wf.user_id and d.is_active;
  if jsonb_array_length(v_rows) = 0 then return jsonb_build_object('ok', false, 'error', '扶養親族の提出がありません（扶養なしの人は反映不要）'); end if;
  v_job := ui_job_enqueue(p_workflow, 'smaregi_dependents', jsonb_build_object('rows', v_rows), v_actor, false);
  if coalesce(v_job ->> 'ok', 'false') = 'true' then update employee_dependents set ui_job_id = (v_job ->> 'job_id')::uuid, updated_at = now() where user_id = wf.user_id and is_active; end if;
  insert into onboarding_events(workflow_id, kind, actor_id, via, payload) values (p_workflow, 'dependents.enqueued', v_actor, 'slack', jsonb_build_object('count', jsonb_array_length(v_rows), 'job', v_job));
  return jsonb_build_object('ok', true, 'count', jsonb_array_length(v_rows), 'job', v_job);
end $$;
grant execute on function public.onboarding_enqueue_dependents(uuid, uuid) to authenticated, service_role;

-- 未提出の人（入社後 p_days 日以上・入社登録の中止でない）。リマインド用
create or replace function public.onboarding_post_join_targets(p_days integer default 3)
returns table(user_id uuid, workflow_id uuid, name text, hire_date date, missing text[], has_slack boolean, has_line boolean, last_reminded_at timestamptz, remind_count integer)
language sql security definer set search_path to 'public' stable
as $$
  select u.id, w.id, u.name, w.hire_date,
         array_remove(array[case when coalesce(s.year_end_status, 'pending') = 'pending' then 'year_end' end, case when coalesce(s.dependents_status, 'pending') = 'pending' then 'dependents' end], null),
         exists(select 1 from user_slack us where us.user_id = u.id), u.line_user_id is not null, s.last_reminded_at, coalesce(s.remind_count, 0)
    from onboarding_workflows w join users u on u.id = w.user_id
    left join employee_post_join_status s on s.user_id = u.id
   where w.status in ('registering', 'completed') and u.is_active
     and coalesce(w.hire_date, w.created_at::date) <= current_date - p_days
     and (coalesce(s.year_end_status, 'pending') = 'pending' or coalesce(s.dependents_status, 'pending') = 'pending')
     and (public.onboarding_is_service() or public.hq_can_manage())
   order by w.hire_date nulls last
$$;
grant execute on function public.onboarding_post_join_targets(integer) to authenticated, service_role;

-- リマインドを記録（EF から）
create or replace function public.onboarding_post_join_reminded(p_user uuid)
returns void language sql security definer set search_path to 'public' as $$
  insert into employee_post_join_status(user_id, workflow_id, last_reminded_at, remind_count)
  values (p_user, (select id from onboarding_workflows where user_id = p_user), now(), 1)
  on conflict (user_id) do update set last_reminded_at = now(), remind_count = employee_post_join_status.remind_count + 1, updated_at = now();
$$;
revoke all on function public.onboarding_post_join_reminded(uuid) from public, anon, authenticated;
grant execute on function public.onboarding_post_join_reminded(uuid) to service_role;

-- 事業所の作成依頼（店舗管理 / 本部）: その契約に対応（store_external_mappings）が無ければジョブを積む
create or replace function public.smaregi_store_create_request(p_store uuid, p_contract text, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; s stores%rowtype; c smaregi_contracts%rowtype; v_pref int; v_payload jsonb; v_job jsonb; v_addr text; v_post text; v_phone text;
  prefs text[] := array['北海道','青森県','岩手県','宮城県','秋田県','山形県','福島県','茨城県','栃木県','群馬県','埼玉県','千葉県','東京都','神奈川県','新潟県','富山県','石川県','福井県','山梨県','長野県','岐阜県','静岡県','愛知県','三重県','滋賀県','京都府','大阪府','兵庫県','奈良県','和歌山県','鳥取県','島根県','岡山県','広島県','山口県','徳島県','香川県','愛媛県','高知県','福岡県','佐賀県','長崎県','熊本県','大分県','宮崎県','鹿児島県','沖縄県'];
  i int;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into s from stores where id = p_store; if s.id is null then raise exception '店舗が見つかりません'; end if;
  select * into c from smaregi_contracts where contract_id = p_contract and is_active; if c.contract_id is null then raise exception '契約が見つかりません'; end if;
  if exists (select 1 from store_external_mappings m where m.store_id = p_store and m.source_system = 'smaregi_timecard' and m.corporation_hint = c.corporation_hint and m.is_active and (m.effective_to is null or m.effective_to >= current_date)) then
    return jsonb_build_object('ok', true, 'already_mapped', true);
  end if;
  -- 住所・電話は店舗マスタ（info.stores。hub_store_id が public.stores.id）にある。無ければ空で作る（スマレジ側は郵便番号が必須なので空なら Mac 側が '000-0000' を入れず not_supported にする）
  select coalesce(i.postal_code, ''), coalesce(i.address, '') || coalesce(i.building, ''), coalesce(i.phone, '') into v_post, v_addr, v_phone from info.stores i where i.hub_store_id = s.id limit 1;
  v_addr := coalesce(v_addr, ''); v_post := coalesce(v_post, ''); v_phone := coalesce(v_phone, '');
  for i in 1..47 loop if v_addr like prefs[i] || '%' then v_pref := i; v_addr := substr(v_addr, length(prefs[i]) + 1); exit; end if; end loop;
  v_payload := jsonb_build_object('store_id', s.id, 'contract_id', p_contract, 'store_name', left(s.name, 50), 'kana', left(coalesce(s.name, ''), 50), 'abbr', left(coalesce(s.display_name, s.name), 15),
                                  'post_code', v_post, 'prefecture_code', v_pref, 'address', left(v_addr, 255), 'phone', v_phone);
  v_job := ui_job_enqueue(null, 'smaregi_store', v_payload, v_actor, false);
  return jsonb_build_object('ok', coalesce(v_job ->> 'ok', 'false') = 'true', 'already_mapped', false, 'job', v_job, 'error', v_job ->> 'error');
end $$;
grant execute on function public.smaregi_store_create_request(uuid, text, uuid) to authenticated, service_role;

-- 作成結果の対応表（EF ui_job_result から・service のみ）
create or replace function public.smaregi_store_mapping_upsert(p_store uuid, p_contract text, p_external_store_id text, p_name text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare c smaregi_contracts%rowtype; v_id uuid;
begin
  if not public.onboarding_is_service() then raise exception 'service_role のみ'; end if;
  select * into c from smaregi_contracts where contract_id = p_contract; if c.contract_id is null then raise exception '契約が見つかりません'; end if;
  if exists (select 1 from store_external_mappings m where m.store_id = p_store and m.source_system = 'smaregi_timecard' and m.corporation_hint = c.corporation_hint and m.is_active and (m.effective_to is null or m.effective_to >= current_date)) then
    return jsonb_build_object('ok', true, 'exists', true);
  end if;
  insert into store_external_mappings(store_id, source_system, external_store_id, external_store_name, corporation_hint, effective_from, is_active, note)
  values (p_store, 'smaregi_timecard', p_external_store_id, p_name, c.corporation_hint, current_date, true, '入社登録 Phase 6: 管理画面の自動操作で作成（' || now()::date || '）') returning id into v_id;
  return jsonb_build_object('ok', true, 'exists', false, 'mapping_id', v_id);
end $$;
revoke all on function public.smaregi_store_mapping_upsert(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.smaregi_store_mapping_upsert(uuid, text, text, text) to service_role;

-- -------------------------------------------------------------
-- 6) ビュー
-- -------------------------------------------------------------
create or replace view public.onboarding_post_join_v as
select u.id as user_id, w.id as workflow_id, u.name as user_name, w.hire_date, w.status as workflow_status,
       coalesce(s.year_end_status, 'pending') as year_end_status, s.year_end_submitted_at, y.sync_status as year_end_sync, y.verified_at as year_end_verified_at,
       coalesce(s.dependents_status, 'pending') as dependents_status, s.dependents_submitted_at,
       (select count(*) from employee_dependents d where d.user_id = u.id and d.is_active) as dependents_count,
       (select count(*) from employee_dependents d where d.user_id = u.id and d.is_active and d.smaregi_synced_at is not null) as dependents_synced,
       s.last_reminded_at, coalesce(s.remind_count, 0) as remind_count
  from onboarding_workflows w join users u on u.id = w.user_id
  left join employee_post_join_status s on s.user_id = u.id
  left join employee_year_end y on y.user_id = u.id;
alter view public.onboarding_post_join_v set (security_invoker = true);
grant select on public.onboarding_post_join_v to authenticated, service_role;

-- onboarding_workflow_v 新版（列追加: year_end / dependents。Slack の親メッセージ用）。w.* の列が増えたため create or replace では列順を変えられず、一度 drop して作り直す（依存ビューなし・grant を再付与）
drop view if exists public.onboarding_workflow_v;
create view public.onboarding_workflow_v as
select w.*, u.name as user_name, u.email as user_email, u.is_active as user_active,
       (select string_agg(s.name, '・' order by s.sort_order) from stores s where s.id = any(w.store_ids)) as store_names,
       (select jsonb_object_agg(i.item_key, jsonb_build_object('state', i.state, 'attempts', i.attempts, 'last_error', i.last_error, 'payload', i.payload, 'completed_at', i.completed_at, 'completion_source', i.completion_source))
          from onboarding_items i where i.workflow_id = w.id) as items,
       (select c.label from smaregi_contracts c where c.contract_id = w.contract_id limit 1) as contract_label,
       (select jsonb_build_object('status', coalesce(s.year_end_status, 'pending'), 'submitted_at', s.year_end_submitted_at, 'sync_status', y.sync_status, 'verified_at', y.verified_at)
          from employee_post_join_status s full join employee_year_end y on y.user_id = s.user_id where coalesce(s.user_id, y.user_id) = w.user_id limit 1) as year_end,
       (select jsonb_build_object('status', coalesce(s.dependents_status, 'pending'), 'submitted_at', s.dependents_submitted_at,
                                  'count', (select count(*) from employee_dependents d where d.user_id = w.user_id and d.is_active),
                                  'synced', (select count(*) from employee_dependents d where d.user_id = w.user_id and d.is_active and d.smaregi_synced_at is not null),
                                  'relationships', (select jsonb_agg(d.relationship order by d.created_at) from employee_dependents d where d.user_id = w.user_id and d.is_active))
          from employee_post_join_status s where s.user_id = w.user_id limit 1) as dependents
  from onboarding_workflows w left join users u on u.id = w.user_id;
alter view public.onboarding_workflow_v set (security_invoker = true);
grant select on public.onboarding_workflow_v to authenticated, service_role;

-- -------------------------------------------------------------
-- 7) 設定とリマインドの cron 用関数（schedule は承認後に手で）
-- -------------------------------------------------------------
update app_settings
   set value = value || jsonb_build_object(
     'post_join_remind_enabled', coalesce((value ->> 'post_join_remind_enabled')::boolean, false),
     'post_join_remind_days', coalesce((value ->> 'post_join_remind_days')::int, 3),
     'post_join_repeat_days', coalesce((value ->> 'post_join_repeat_days')::int, 3))
 where key = 'onboarding_alerts';

create or replace function public.onboarding_post_join_remind_trigger()
returns void
language plpgsql security definer set search_path to 'public', 'net', 'extensions'
as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/onboarding-notify';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text; v_req bigint;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'onboarding_post_join_remind_trigger: notify_slack_secret 未設定'; return; end if;
  select net.http_post(url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'post_join_remind', 'trigger', 'pg_cron'), timeout_milliseconds := 120000) into v_req;
end $$;
revoke all on function public.onboarding_post_join_remind_trigger() from public, anon, authenticated;
-- cron（承認後に手で。EF 側も onboarding_alerts.post_join_remind_enabled=true でないと送らない）:
--   select cron.schedule('onboarding-post-join-remind', '30 0 * * *', $$select public.onboarding_post_join_remind_trigger()$$);   -- 09:30 JST
--   止める: select cron.unschedule('onboarding-post-join-remind');
