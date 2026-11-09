-- =============================================================
-- 入社登録 Phase 6（2026-11-09・★ 本番未適用。v2 2026-11-09 改訂＝ユーザー最終方針①〜⑨を反映）
--   v1: ①店舗 → スマレジ事業所の自動作成 ②入社後の本人フォーム（扶養・年末調整）→ 管理システム → Playwright ③源泉所得税の Slack 画面統一
--   v2: 社員・アルバイト全員が対象。提出必須・リマインドは「雇用区分の標準ルール（post_join_rules）」＋「従業員個別の上書き（post_join_overrides）」で決め、
--       変更は履歴（post_join_policy_history）に残す。年末調整は対象年度ごと。提出 → 本部の承認（approved）→ スマレジ反映。
--       既存従業員はスマレジの内容を 1 人ずつ取り込んで（snapshot）本人が確認・変更申請できる。雇用区分の変更だけでは税務情報を消さない・上書きしない。
--   注記（方針①）: 「任意」は社内運用上の扱いであり、税法上の提出・申告の義務を免除するものではない（nippo の画面と設計書にも明記）。
--   個人情報（氏名・住所・生年月日）は DB の中だけ。Slack には件数・続柄だけ。マイナンバーは預からない。
--   適用順: Phase 5 準備 SQL（2026-11-09_onboarding_phase5_prep.sql）の後。切り戻し: 2026-11-09_onboarding_phase6_rollback.sql（データ保全版）
-- =============================================================

-- -------------------------------------------------------------
-- 0) 共通: 雇用区分（class）・対象年度（JST）
-- -------------------------------------------------------------
create or replace function public.post_join_class(p_role text)
returns text language sql immutable as $$ select case when p_role = 'AL' then 'AL' else 'SHAIN' end $$;
create or replace function public.post_join_year_default()
returns integer language sql stable as $$ select extract(year from (now() at time zone 'Asia/Tokyo'))::int $$;

-- -------------------------------------------------------------
-- 1) 表
-- -------------------------------------------------------------
-- 年末調整（対象年度ごと）。列名はスマレジ /staffs/edit_year_end と同じ
create table if not exists public.employee_year_end (
  user_id                                  uuid not null references public.users(id) on delete cascade,
  target_year                              integer not null default public.post_join_year_default(),
  workflow_id                              uuid references public.onboarding_workflows(id) on delete set null,
  household_header_name                    text,                       -- 世帯主（32 文字以内）
  household_header_relationship            integer,                    -- 0 本人 … 14 義母 / 99 その他
  spouse_flag                              boolean not null default false,
  estimate_income                          integer not null default 0, -- 合計所得見積額（円）
  retirement_income                        integer not null default 0, -- 退職所得（円）
  handicapped_division                     integer not null default 1 check (handicapped_division in (1,2,3)),
  widow_division2                          integer not null default 1 check (widow_division2 in (1,2,3)),
  widow_division                           integer not null default 1 check (widow_division in (1,2,3,4)),
  student_flag                             boolean not null default false,
  salary_payment_report_collection_division integer not null default 1 check (salary_payment_report_collection_division in (1,2)),
  submitted_at                             timestamptz,
  submitted_via                            text,                       -- nippo_self / nippo_hq / nippo_join
  confirmed_by                             uuid,
  confirmed_at                             timestamptz,
  ui_job_id                                uuid,
  sync_status                              text not null default 'pending' check (sync_status in ('pending','queued','synced','error','manual','skipped')),
  sync_error                               text,
  verified_at                              timestamptz,
  verified_value                           jsonb,
  created_at                               timestamptz not null default now(),
  updated_at                               timestamptz not null default now(),
  primary key (user_id, target_year)
);
alter table public.employee_year_end enable row level security;
drop policy if exists employee_year_end_read on public.employee_year_end;
create policy employee_year_end_read on public.employee_year_end for select to authenticated using (public.hq_can_manage() or user_id = auth.uid());

-- スマレジに今登録されている年末調整（API GET の yearEnd）。1 人ずつ取り込む。本人提出とは別に保持（上書きしない）
create table if not exists public.employee_year_end_snapshot (
  user_id      uuid not null references public.users(id) on delete cascade,
  target_year  integer not null,
  data         jsonb not null,
  fetched_at   timestamptz not null default now(),
  fetched_by   uuid,
  primary key (user_id, target_year)
);
alter table public.employee_year_end_snapshot enable row level security;
drop policy if exists employee_year_end_snapshot_read on public.employee_year_end_snapshot;
create policy employee_year_end_snapshot_read on public.employee_year_end_snapshot for select to authenticated using (public.hq_can_manage() or user_id = auth.uid());

-- 扶養親族 1 人 1 行。source: self（本人提出）/ hq（本部代理）/ smaregi_snapshot（スマレジから読んだ参考値・is_active=false）
create table if not exists public.employee_dependents (
  id                        uuid primary key default gen_random_uuid(),
  user_id                   uuid not null references public.users(id) on delete cascade,
  workflow_id               uuid references public.onboarding_workflows(id) on delete set null,
  name                      text not null,
  kana                      text not null default '',
  relationship              integer not null,                          -- 1 配偶者 … 14 義母 / 99 その他
  birthday                  date,
  living_together_division  integer not null default 1 check (living_together_division in (1,2,3)),
  post_code                 text,
  address                   text,
  estimate_income           integer not null default 0,
  retirement_income         integer not null default 0,
  handicapped_division      integer not null default 1 check (handicapped_division in (1,2,3)),
  is_active                 boolean not null default true,
  source                    text not null default 'self' check (source in ('self','hq','smaregi_snapshot')),
  confirmed_at              timestamptz,
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

-- 提出状況（本人 × トラック × 対象年度。扶養は target_year=0）
create table if not exists public.employee_post_join_status (
  user_id        uuid not null references public.users(id) on delete cascade,
  track          text not null check (track in ('dependents','year_end')),
  target_year    integer not null default 0,
  workflow_id    uuid references public.onboarding_workflows(id) on delete set null,
  status         text not null default 'pending' check (status in ('pending','submitted','approved','queued','synced','error','skipped','none','not_target')),
  submitted_at   timestamptz,
  approved_by    uuid,
  approved_at    timestamptz,
  last_reminded_at timestamptz,
  remind_count   integer not null default 0,
  source         text,                                  -- self / hq / smaregi_snapshot
  note           text,
  updated_at     timestamptz not null default now(),
  primary key (user_id, track, target_year)
);
alter table public.employee_post_join_status enable row level security;
drop policy if exists employee_post_join_status_read on public.employee_post_join_status;
create policy employee_post_join_status_read on public.employee_post_join_status for select to authenticated using (public.hq_can_manage() or user_id = auth.uid());

-- 雇用区分の標準ルール（class × track）
create table if not exists public.post_join_rules (
  class                               text not null check (class in ('SHAIN','AL')),
  track                               text not null check (track in ('dependents','year_end')),
  form_enabled                        boolean not null default true,    -- フォーム利用可否
  invite_on_join                      boolean not null default true,    -- 入社時に案内する
  required                            boolean not null default false,   -- 提出必須（社内運用上）
  remind_enabled                      boolean not null default false,   -- リマインド
  deadline_days                       integer,                          -- 扶養: 入社日から n 日（null=期限なし）
  payroll_closing_day                 integer check (payroll_closing_day is null or payroll_closing_day between 1 and 31),  -- 扶養: 給与締め日（31=末日）。入社後最初の締め日 − payroll_lead_days を「初回給与処理に必要な期限」とし、deadline_days と早い方を採用（2026-11-09 ユーザー指示）
  payroll_lead_days                   integer not null default 5,       -- 締め日の何日前までに扶養情報が必要か
  deadline_month_day                  text,                             -- 年末調整: 対象年度の 'MM-DD'（null=期限なし）
  remind_interval_days                integer not null default 3,       -- 期限前の間隔
  remind_interval_after_deadline_days integer not null default 1,       -- 期限後の間隔
  year_end_target_rule                text not null default 'all' check (year_end_target_rule in ('all','none')),  -- 年末調整の対象判定の既定（個別 target で上書き可）
  note                                text,
  updated_by                          uuid,
  updated_at                          timestamptz not null default now(),
  primary key (class, track)
);
alter table public.post_join_rules enable row level security;
drop policy if exists post_join_rules_read on public.post_join_rules;
create policy post_join_rules_read on public.post_join_rules for select to authenticated using (true);
insert into public.post_join_rules(class, track, form_enabled, invite_on_join, required, remind_enabled, deadline_days, deadline_month_day, note) values
  ('SHAIN', 'dependents', true, true, true,  true,  14,   null,    '社員: 扶養フォームは社内運用上 提出必須。期限＝入社 14 日後 と 初回給与処理に必要な期限（入社後最初の締め日 − リード日数）の早い方'),
  ('SHAIN', 'year_end',   true, true, true,  true,  null, '11-30', '社員: 年末調整は対象年度ごとに対象判定（既定 all）。対象者は提出必須。11/30 まで'),
  ('AL',    'dependents', true, true, false, false, null, null,    'アルバイト: 利用可・初期は任意・リマインドなし（本部が個別に必須へ変更可）'),
  ('AL',    'year_end',   true, true, false, false, null, '11-30', 'アルバイト: 利用可・初期は任意・リマインドなし（本部が個別に必須へ変更可）')
on conflict (class, track) do nothing;
-- 社員の扶養: 給与締め日（★仮置き: 末日締め・5 日前。実際の締め日と給与処理のリード日数はユーザー確認後に標準ルール画面で変更）
update public.post_join_rules set payroll_closing_day = 31, payroll_lead_days = 5 where class = 'SHAIN' and track = 'dependents' and payroll_closing_day is null;

-- 従業員個別の上書き（null の項目は標準ルール）。理由必須・変更は履歴へ
create table if not exists public.post_join_overrides (
  user_id        uuid not null references public.users(id) on delete cascade,
  track          text not null check (track in ('dependents','year_end')),
  target_year    integer not null default 0,
  form_enabled   boolean,
  required       boolean,
  remind_enabled boolean,
  deadline       date,
  target         boolean,                               -- 年末調整の対象判定（null=標準ルール）
  reason         text not null,
  changed_by     uuid,
  changed_at     timestamptz not null default now(),
  primary key (user_id, track, target_year)
);
alter table public.post_join_overrides enable row level security;
drop policy if exists post_join_overrides_read on public.post_join_overrides;
create policy post_join_overrides_read on public.post_join_overrides for select to authenticated using (public.hq_can_manage() or user_id = auth.uid());

-- 履歴（追記のみ）
create table if not exists public.post_join_policy_history (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid,
  class        text,
  track        text,
  target_year  integer,
  kind         text not null check (kind in ('rule_changed','override_set','override_cleared','class_changed','status_changed','approved','rejected','skipped','choice','snapshot_imported','snapshot_requested')),
  before       jsonb,
  after        jsonb,
  reason       text,
  actor_id     uuid,
  created_at   timestamptz not null default now()
);
create index if not exists post_join_policy_history_user_idx on public.post_join_policy_history(user_id, created_at desc);
alter table public.post_join_policy_history enable row level security;
drop policy if exists post_join_policy_history_read on public.post_join_policy_history;
create policy post_join_policy_history_read on public.post_join_policy_history for select to authenticated using (public.hq_can_manage() or user_id = auth.uid());

-- 履歴トリガー: ルール・上書き・雇用区分（users.role の class が変わったとき）
create or replace function public.post_join_history_rules() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  insert into post_join_policy_history(class, track, kind, before, after, reason, actor_id)
  values (coalesce(new.class, old.class), coalesce(new.track, old.track), 'rule_changed', case when tg_op = 'INSERT' then null else to_jsonb(old) end, case when tg_op = 'DELETE' then null else to_jsonb(new) end, coalesce(new.note, old.note), coalesce(new.updated_by, old.updated_by));
  return coalesce(new, old);
end $$;
drop trigger if exists trg_post_join_rules_history on public.post_join_rules;
create trigger trg_post_join_rules_history after insert or update or delete on public.post_join_rules for each row execute function public.post_join_history_rules();

create or replace function public.post_join_history_overrides() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  insert into post_join_policy_history(user_id, track, target_year, kind, before, after, reason, actor_id)
  values (coalesce(new.user_id, old.user_id), coalesce(new.track, old.track), coalesce(new.target_year, old.target_year),
          case when tg_op = 'DELETE' then 'override_cleared' else 'override_set' end,
          case when tg_op = 'INSERT' then null else to_jsonb(old) end, case when tg_op = 'DELETE' then null else to_jsonb(new) end,
          coalesce(new.reason, old.reason), coalesce(new.changed_by, old.changed_by));
  return coalesce(new, old);
end $$;
drop trigger if exists trg_post_join_overrides_history on public.post_join_overrides;
create trigger trg_post_join_overrides_history after insert or update or delete on public.post_join_overrides for each row execute function public.post_join_history_overrides();

-- 雇用区分の変更（AL ⇄ 社員）: 履歴に残すだけ。提出済みデータ・上書き・状態は一切触らない（方針④）
create or replace function public.post_join_history_class_change() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if public.post_join_class(old.role) is distinct from public.post_join_class(new.role) then
    insert into post_join_policy_history(user_id, class, kind, before, after, reason, actor_id)
    values (new.id, public.post_join_class(new.role), 'class_changed', jsonb_build_object('role', old.role, 'class', public.post_join_class(old.role)), jsonb_build_object('role', new.role, 'class', public.post_join_class(new.role)),
            '雇用区分の変更（標準ルールが切り替わる。提出済みデータは保持）', auth.uid());
  end if;
  return new;
end $$;
drop trigger if exists trg_post_join_class_change on public.users;
create trigger trg_post_join_class_change after update of role on public.users for each row execute function public.post_join_history_class_change();

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
declare v_actor uuid; wf onboarding_workflows%rowtype; v_item text; v_job uuid; v_staff text; v_contract text; v_payload jsonb;
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
    if coalesce(p_payload ->> 'store_id', '') = '' or coalesce(p_payload ->> 'contract_id', '') = '' then raise exception '店舗ジョブには payload.store_id と contract_id が必要です'; end if;
    v_staff := 'store:' || (p_payload ->> 'store_id'); v_contract := p_payload ->> 'contract_id'; v_item := null;
  else
    select * into wf from onboarding_workflows where id = p_workflow;
    if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
    select l.contract_id, l.smaregi_staff_id into v_contract, v_staff from employee_smaregi_links l
     where l.user_id = wf.user_id and l.effective_to is null order by l.is_primary desc, l.effective_from desc limit 1;
    if v_staff is null then raise exception 'スマレジに登録されていないためジョブを作れません'; end if;
    v_item := case p_kind when 'smaregi_commute' then 'commute_set' when 'smaregi_tax' then 'withholding_tax' when 'smaregi_payslip' then 'web_payslip' when 'smaregi_email' then 'email' else null end;
    -- 書き込み前の 3 点確認（2026-11-09 ユーザー指示）: Mac 側が 契約ID・従業員ID・所属事業所 を画面で照合してから書く。期待値を payload に必ず入れる
    --   expected_stores = その人の user_stores の店舗を、その契約の store_external_mappings（smaregi_timecard・有効・期間内）の external_store_name に変換。対応が無い店舗は stores.name のまま
    v_payload := coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('expected_contract_id', v_contract, 'expected_staff_id', v_staff,
      'expected_stores', (select coalesce(jsonb_agg(coalesce(
            (select m.external_store_name from store_external_mappings m join smaregi_contracts c on c.corporation_hint = m.corporation_hint and c.contract_id = v_contract
              where m.store_id = s.id and m.source_system = 'smaregi_timecard' and m.is_active and (m.effective_from is null or m.effective_from <= current_date) and (m.effective_to is null or m.effective_to >= current_date)
              order by m.effective_from desc nulls last limit 1), s.name) order by s.sort_order), '[]'::jsonb)
         from user_stores us join stores s on s.id = us.store_id where us.user_id = wf.user_id));
  end if;
  begin
    insert into ui_automation_jobs(kind, workflow_id, item_key, user_id, contract_id, smaregi_staff_id, payload, dry_run, requested_by)
    values (p_kind, case when p_kind = 'smaregi_store' then null else p_workflow end, v_item, wf.user_id, v_contract, v_staff, coalesce(v_payload, p_payload, '{}'::jsonb), coalesce(p_dry_run, false), v_actor)
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
-- 5) 権限ヘルパー
-- -------------------------------------------------------------
-- 本人（または本部・service）かどうか。戻り値は操作者
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

-- -------------------------------------------------------------
-- 6) 実効ポリシー（class のルール + 個別上書き + 状態）
-- -------------------------------------------------------------
-- 内部版（権限確認なし。ビューと他の関数から使う）
-- 初回給与処理に必要な期限: 入社日以降で最初の給与締め日（closing_day=31 は月末）− lead_days。それが入社 2 日未満なら次の締め日で計算
create or replace function public.post_join_payroll_deadline(p_hire date, p_closing_day integer, p_lead_days integer)
returns date language plpgsql immutable as $$
declare v_close date; v_dl date; v_month date;
begin
  if p_hire is null or p_closing_day is null then return null; end if;
  v_month := date_trunc('month', p_hire)::date;
  for i in 0..2 loop
    v_close := least((v_month + interval '1 month' - interval '1 day')::date, v_month + (p_closing_day - 1));
    v_dl := v_close - coalesce(p_lead_days, 0);
    if v_close >= p_hire and v_dl >= p_hire + 2 then return v_dl; end if;
    v_month := (v_month + interval '1 month')::date;
  end loop;
  return v_dl;
end $$;

create or replace function public.post_join_effective_i(p_user uuid, p_track text, p_year integer default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_role text; v_class text; r post_join_rules%rowtype; o post_join_overrides%rowtype; s employee_post_join_status%rowtype;
        v_year int; v_hire date; v_deadline date; v_payroll date; v_deadline_reason text; v_required bool; v_remind bool; v_enabled bool; v_invite bool; v_target bool; v_src text := 'rule'; v_status text;
begin
  if p_track not in ('dependents','year_end') then raise exception 'track が不正です'; end if;
  v_year := case when p_track = 'dependents' then 0 else coalesce(p_year, public.post_join_year_default()) end;
  select role into v_role from users where id = p_user;
  if v_role is null then raise exception '従業員が見つかりません'; end if;
  v_class := public.post_join_class(v_role);
  select * into r from post_join_rules where class = v_class and track = p_track;
  select * into o from post_join_overrides where user_id = p_user and track = p_track and target_year = v_year;
  select coalesce(p.hire_date, u.created_at::date) into v_hire from users u left join employee_profiles p on p.user_id = u.id where u.id = p_user;
  v_enabled := coalesce(o.form_enabled, r.form_enabled, true);
  v_invite  := coalesce(r.invite_on_join, true);
  v_target  := coalesce(o.target, case when p_track = 'year_end' then coalesce(r.year_end_target_rule, 'all') = 'all' else true end);
  v_required := coalesce(o.required, r.required, false) and v_target;
  v_remind   := coalesce(o.remind_enabled, r.remind_enabled, false) and v_required;
  -- 扶養の期限: 「入社 n 日後」と「初回給与処理に必要な期限（入社後最初の給与締め日 − リード日数。入社から 2 日未満になるなら次の締め日）」の早い方（2026-11-09 ユーザー指示）
  if p_track = 'dependents' then
    v_deadline := case when r.deadline_days is null then null else v_hire + r.deadline_days end;
    if r.payroll_closing_day is not null and v_hire is not null then
      v_payroll := public.post_join_payroll_deadline(v_hire, r.payroll_closing_day, coalesce(r.payroll_lead_days, 0));
      if v_deadline is null or v_payroll < v_deadline then v_deadline := v_payroll; v_deadline_reason := 'payroll'; else v_deadline_reason := 'days'; end if;
    elsif v_deadline is not null then v_deadline_reason := 'days'; end if;
  else
    v_deadline := case when r.deadline_month_day is null then null else to_date(v_year::text || '-' || r.deadline_month_day, 'YYYY-MM-DD') end;
    if v_deadline is not null then v_deadline_reason := 'year_end'; end if;
  end if;
  if o.deadline is not null then v_deadline := o.deadline; v_deadline_reason := 'override'; end if;
  if o.user_id is not null then v_src := 'override'; end if;
  select * into s from employee_post_join_status where user_id = p_user and track = p_track and target_year = v_year;
  v_status := coalesce(s.status, case when not v_target then 'not_target' else 'pending' end);
  return jsonb_build_object('user_id', p_user, 'track', p_track, 'target_year', v_year, 'class', v_class, 'role', v_role, 'hire_date', v_hire,
    'form_enabled', v_enabled, 'invite_on_join', v_invite, 'target', v_target, 'required', v_required, 'remind_enabled', v_remind, 'deadline', v_deadline, 'deadline_reason', v_deadline_reason,
    'source_of_required', v_src, 'override_reason', o.reason, 'status', v_status, 'submitted_at', s.submitted_at, 'approved_at', s.approved_at,
    'last_reminded_at', s.last_reminded_at, 'remind_count', coalesce(s.remind_count, 0),
    'remind_interval_days', coalesce(r.remind_interval_days, 3), 'remind_interval_after_deadline_days', coalesce(r.remind_interval_after_deadline_days, 1),
    'legal_note', '「任意」は社内運用上の扱いです。税法上の提出・申告の義務を免除するものではありません');
end $$;
revoke all on function public.post_join_effective_i(uuid, text, integer) from public, anon;
grant execute on function public.post_join_effective_i(uuid, text, integer) to authenticated, service_role;

-- 公開版（本人 or 本部 or service）
create or replace function public.post_join_effective(p_user uuid, p_track text, p_year integer default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  perform public.onboarding_self_or_hq(p_user, null);
  return public.post_join_effective_i(p_user, p_track, p_year);
end $$;
grant execute on function public.post_join_effective(uuid, text, integer) to authenticated, service_role;

-- 個別の上書き（本部のみ・理由必須）。p_patch のキー: form_enabled / required / remind_enabled / deadline / target（null で「標準ルールに戻す」）
create or replace function public.post_join_set_override(p_user uuid, p_track text, p_year integer, p_patch jsonb, p_reason text, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; v_year int; o post_join_overrides%rowtype;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_track not in ('dependents','year_end') then raise exception 'track が不正です'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception '変更理由を入れてください'; end if;
  v_year := case when p_track = 'dependents' then 0 else coalesce(p_year, public.post_join_year_default()) end;
  select * into o from post_join_overrides where user_id = p_user and track = p_track and target_year = v_year;
  insert into post_join_overrides(user_id, track, target_year, form_enabled, required, remind_enabled, deadline, target, reason, changed_by, changed_at)
  values (p_user, p_track, v_year,
          case when p_patch ? 'form_enabled' then (p_patch ->> 'form_enabled')::boolean else o.form_enabled end,
          case when p_patch ? 'required' then (p_patch ->> 'required')::boolean else o.required end,
          case when p_patch ? 'remind_enabled' then (p_patch ->> 'remind_enabled')::boolean else o.remind_enabled end,
          case when p_patch ? 'deadline' then nullif(p_patch ->> 'deadline', '')::date else o.deadline end,
          case when p_patch ? 'target' then (p_patch ->> 'target')::boolean else o.target end,
          p_reason, v_actor, now())
  on conflict (user_id, track, target_year) do update set form_enabled = excluded.form_enabled, required = excluded.required, remind_enabled = excluded.remind_enabled,
     deadline = excluded.deadline, target = excluded.target, reason = excluded.reason, changed_by = excluded.changed_by, changed_at = now();
  -- 対象外にしたら状態も not_target に（提出済みのデータは消さない）。対象に戻したら pending へ
  if p_patch ? 'target' then
    if (p_patch ->> 'target')::boolean = false then
      insert into employee_post_join_status(user_id, track, target_year, status, note) values (p_user, p_track, v_year, 'not_target', p_reason)
      on conflict (user_id, track, target_year) do update set status = case when employee_post_join_status.status in ('pending') then 'not_target' else employee_post_join_status.status end, note = p_reason, updated_at = now();
    else
      update employee_post_join_status set status = 'pending', note = p_reason, updated_at = now() where user_id = p_user and track = p_track and target_year = v_year and status = 'not_target';
    end if;
  end if;
  return public.post_join_effective_i(p_user, p_track, v_year);
end $$;
grant execute on function public.post_join_set_override(uuid, text, integer, jsonb, text, uuid) to authenticated, service_role;

create or replace function public.post_join_clear_override(p_user uuid, p_track text, p_year integer, p_reason text, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_actor uuid; v_year int;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if coalesce(trim(p_reason), '') = '' then raise exception '理由を入れてください'; end if;
  v_year := case when p_track = 'dependents' then 0 else coalesce(p_year, public.post_join_year_default()) end;
  update post_join_overrides set reason = p_reason, changed_by = v_actor where user_id = p_user and track = p_track and target_year = v_year;  -- 履歴に理由を残してから消す
  delete from post_join_overrides where user_id = p_user and track = p_track and target_year = v_year;
  return public.post_join_effective_i(p_user, p_track, v_year);
end $$;
grant execute on function public.post_join_clear_override(uuid, text, integer, text, uuid) to authenticated, service_role;

-- 標準ルールの変更（マスター・社長のみ・理由必須）
create or replace function public.post_join_set_rule(p_class text, p_track text, p_patch jsonb, p_reason text, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_actor uuid;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if not exists (select 1 from users u where u.id = v_actor and (u.is_master or u.role = 'CEO')) then raise exception '標準ルールの変更はマスター・社長のみです'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception '変更理由を入れてください'; end if;
  update post_join_rules set
    form_enabled = coalesce((p_patch ->> 'form_enabled')::boolean, form_enabled), invite_on_join = coalesce((p_patch ->> 'invite_on_join')::boolean, invite_on_join),
    required = coalesce((p_patch ->> 'required')::boolean, required), remind_enabled = coalesce((p_patch ->> 'remind_enabled')::boolean, remind_enabled),
    deadline_days = case when p_patch ? 'deadline_days' then nullif(p_patch ->> 'deadline_days', '')::int else deadline_days end,
    payroll_closing_day = case when p_patch ? 'payroll_closing_day' then nullif(p_patch ->> 'payroll_closing_day', '')::int else payroll_closing_day end,
    payroll_lead_days = coalesce((p_patch ->> 'payroll_lead_days')::int, payroll_lead_days),
    deadline_month_day = case when p_patch ? 'deadline_month_day' then nullif(p_patch ->> 'deadline_month_day', '') else deadline_month_day end,
    remind_interval_days = coalesce((p_patch ->> 'remind_interval_days')::int, remind_interval_days),
    remind_interval_after_deadline_days = coalesce((p_patch ->> 'remind_interval_after_deadline_days')::int, remind_interval_after_deadline_days),
    year_end_target_rule = coalesce(p_patch ->> 'year_end_target_rule', year_end_target_rule),
    note = p_reason, updated_by = v_actor, updated_at = now()
  where class = p_class and track = p_track;
  if not found then raise exception 'ルールが見つかりません'; end if;
  return (select to_jsonb(r) from post_join_rules r where class = p_class and track = p_track);
end $$;
grant execute on function public.post_join_set_rule(text, text, jsonb, text, uuid) to authenticated, service_role;

-- -------------------------------------------------------------
-- 7) 提出（本人・本部代理）・選択・不要・承認・差し戻し
-- -------------------------------------------------------------
-- 状態の更新＋履歴（内部）
create or replace function public.post_join_set_status_i(p_user uuid, p_track text, p_year integer, p_status text, p_actor uuid, p_kind text, p_note text default null, p_source text default null)
returns void language plpgsql security definer set search_path to 'public' as $$
declare v_wf uuid; v_before text;
begin
  select id into v_wf from onboarding_workflows where user_id = p_user;
  select status into v_before from employee_post_join_status where user_id = p_user and track = p_track and target_year = p_year;
  insert into employee_post_join_status(user_id, track, target_year, workflow_id, status, submitted_at, approved_by, approved_at, source, note)
  values (p_user, p_track, p_year, v_wf, p_status, case when p_status in ('submitted','none') then now() end, case when p_status = 'approved' then p_actor end, case when p_status = 'approved' then now() end, p_source, p_note)
  on conflict (user_id, track, target_year) do update set
    status = excluded.status, workflow_id = coalesce(employee_post_join_status.workflow_id, excluded.workflow_id),
    submitted_at = case when excluded.status in ('submitted','none') then now() else employee_post_join_status.submitted_at end,
    approved_by = case when excluded.status = 'approved' then p_actor when excluded.status in ('pending','submitted') then null else employee_post_join_status.approved_by end,
    approved_at = case when excluded.status = 'approved' then now() when excluded.status in ('pending','submitted') then null else employee_post_join_status.approved_at end,
    source = coalesce(excluded.source, employee_post_join_status.source), note = coalesce(excluded.note, employee_post_join_status.note), updated_at = now();
  insert into post_join_policy_history(user_id, track, target_year, kind, before, after, reason, actor_id)
  values (p_user, p_track, p_year, p_kind, jsonb_build_object('status', v_before), jsonb_build_object('status', p_status), p_note, p_actor);
  if v_wf is not null then
    insert into onboarding_events(workflow_id, kind, actor_id, via, payload) values (v_wf, 'post_join.' || p_kind, p_actor, case when auth.uid() is null then 'system' else 'nippo' end, jsonb_build_object('track', p_track, 'target_year', p_year, 'status', p_status, 'note', p_note));
  end if;
end $$;
revoke all on function public.post_join_set_status_i(uuid, text, integer, text, uuid, text, text, text) from public, anon, authenticated;

-- 入社時の選択（今入力する／後から入力する）。状態は pending のまま・履歴に残す
create or replace function public.onboarding_post_join_choice(p_user uuid, p_track text, p_choice text, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_actor uuid; v_wf uuid; v_year int;
begin
  v_actor := public.onboarding_self_or_hq(p_user, p_actor);
  if p_track not in ('dependents','year_end') then raise exception 'track が不正です'; end if;
  if p_choice not in ('now','later') then raise exception 'choice は now か later'; end if;
  v_year := case when p_track = 'dependents' then 0 else public.post_join_year_default() end;
  select id into v_wf from onboarding_workflows where user_id = p_user;
  insert into employee_post_join_status(user_id, track, target_year, workflow_id) values (p_user, p_track, v_year, v_wf) on conflict do nothing;
  insert into post_join_policy_history(user_id, track, target_year, kind, after, actor_id) values (p_user, p_track, v_year, 'choice', jsonb_build_object('choice', p_choice), v_actor);
  if v_wf is not null then insert into onboarding_events(workflow_id, kind, actor_id, via, payload) values (v_wf, 'post_join.choice', v_actor, 'nippo', jsonb_build_object('track', p_track, 'choice', p_choice)); end if;
  return jsonb_build_object('ok', true, 'track', p_track, 'target_year', v_year, 'choice', p_choice);
end $$;
grant execute on function public.onboarding_post_join_choice(uuid, text, text, uuid) to authenticated, service_role;

-- 年末調整の提出（本人 / 本部代理）。p_data はスマレジの列名そのまま。年度ごと
create or replace function public.onboarding_save_year_end(p_user uuid, p_data jsonb, p_via text default 'nippo_self', p_actor uuid default null, p_year integer default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; v_wf uuid; v_year int; v_before jsonb; v_eff jsonb;
begin
  v_actor := public.onboarding_self_or_hq(p_user, p_actor);
  v_year := coalesce(p_year, public.post_join_year_default());
  v_eff := public.post_join_effective_i(p_user, 'year_end', v_year);
  if (v_eff ->> 'form_enabled')::boolean = false then raise exception 'このフォームは利用できない設定です（本部に確認してください）'; end if;
  select id into v_wf from onboarding_workflows where user_id = p_user;
  select to_jsonb(y) into v_before from employee_year_end y where y.user_id = p_user and y.target_year = v_year;
  insert into employee_year_end(user_id, target_year, workflow_id, household_header_name, household_header_relationship, spouse_flag, estimate_income, retirement_income,
                                handicapped_division, widow_division2, widow_division, student_flag, salary_payment_report_collection_division, submitted_at, submitted_via, sync_status)
  values (p_user, v_year, v_wf, left(nullif(trim(coalesce(p_data ->> 'household_header_name', '')), ''), 32), nullif(p_data ->> 'household_header_relationship', '')::int,
          coalesce((p_data ->> 'spouse_flag')::boolean, false), coalesce(nullif(p_data ->> 'estimate_income', '')::int, 0), coalesce(nullif(p_data ->> 'retirement_income', '')::int, 0),
          coalesce(nullif(p_data ->> 'handicapped_division', '')::int, 1), coalesce(nullif(p_data ->> 'widow_division2', '')::int, 1), coalesce(nullif(p_data ->> 'widow_division', '')::int, 1),
          coalesce((p_data ->> 'student_flag')::boolean, false), coalesce(nullif(p_data ->> 'salary_payment_report_collection_division', '')::int, 1), now(), coalesce(p_via, 'nippo_self'), 'pending')
  on conflict (user_id, target_year) do update set
    workflow_id = coalesce(employee_year_end.workflow_id, excluded.workflow_id), household_header_name = excluded.household_header_name, household_header_relationship = excluded.household_header_relationship,
    spouse_flag = excluded.spouse_flag, estimate_income = excluded.estimate_income, retirement_income = excluded.retirement_income, handicapped_division = excluded.handicapped_division,
    widow_division2 = excluded.widow_division2, widow_division = excluded.widow_division, student_flag = excluded.student_flag,
    salary_payment_report_collection_division = excluded.salary_payment_report_collection_division, submitted_at = now(), submitted_via = excluded.submitted_via,
    sync_status = 'pending', sync_error = null, ui_job_id = null, confirmed_by = null, confirmed_at = null, updated_at = now();
  -- 再提出は承認を取り直す（submitted に戻る）
  perform public.post_join_set_status_i(p_user, 'year_end', v_year, 'submitted', v_actor, 'status_changed', '本人提出（' || coalesce(p_via, 'nippo_self') || '）', case when p_via like 'nippo_hq%' then 'hq' else 'self' end);
  if v_wf is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (v_wf, null, 'year_end.submitted', v_actor, case when auth.uid() is null then 'system' else 'nippo' end,
            case when v_before is null then null else jsonb_build_object('submitted_at', v_before ->> 'submitted_at') end,
            jsonb_build_object('target_year', v_year, 'spouse_flag', coalesce((p_data ->> 'spouse_flag')::boolean, false), 'student_flag', coalesce((p_data ->> 'student_flag')::boolean, false), 'via', p_via));
  end if;
  return jsonb_build_object('ok', true, 'workflow_id', v_wf, 'target_year', v_year, 'required', v_eff -> 'required', 'deadline', v_eff -> 'deadline');
end $$;
grant execute on function public.onboarding_save_year_end(uuid, jsonb, text, uuid, integer) to authenticated, service_role;

-- 扶養親族の提出: 今の有効行（self/hq）を全部無効にして p_rows を入れ直す。0 件＝「扶養なし」。snapshot 行は触らない
create or replace function public.onboarding_save_dependents(p_user uuid, p_rows jsonb, p_via text default 'nippo_self', p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; v_wf uuid; r jsonb; n int := 0; v_rel int; v_eff jsonb; v_src text;
begin
  v_actor := public.onboarding_self_or_hq(p_user, p_actor);
  if p_rows is not null and jsonb_typeof(p_rows) <> 'array' then raise exception 'p_rows は配列で渡してください'; end if;
  v_eff := public.post_join_effective_i(p_user, 'dependents', 0);
  if (v_eff ->> 'form_enabled')::boolean = false then raise exception 'このフォームは利用できない設定です（本部に確認してください）'; end if;
  v_src := case when p_via like 'nippo_hq%' then 'hq' else 'self' end;
  select id into v_wf from onboarding_workflows where user_id = p_user;
  update employee_dependents set is_active = false, updated_at = now() where user_id = p_user and is_active and source <> 'smaregi_snapshot';
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    if coalesce(trim(r ->> 'name'), '') = '' then raise exception '扶養親族の名前は必須です'; end if;
    v_rel := nullif(r ->> 'relationship', '')::int;
    if v_rel is null or not (v_rel between 1 and 14 or v_rel = 99) then raise exception '続柄が不正です'; end if;
    insert into employee_dependents(user_id, workflow_id, name, kana, relationship, birthday, living_together_division, post_code, address, estimate_income, retirement_income, handicapped_division, source, confirmed_at, submitted_at, submitted_via)
    values (p_user, v_wf, left(trim(r ->> 'name'), 50), left(coalesce(r ->> 'kana', ''), 50), v_rel, nullif(r ->> 'birthday', '')::date,
            coalesce(nullif(r ->> 'living_together_division', '')::int, 1), nullif(r ->> 'post_code', ''), left(coalesce(r ->> 'address', ''), 200),
            coalesce(nullif(r ->> 'estimate_income', '')::int, 0), coalesce(nullif(r ->> 'retirement_income', '')::int, 0), coalesce(nullif(r ->> 'handicapped_division', '')::int, 1),
            v_src, case when v_src = 'self' then now() end, now(), coalesce(p_via, 'nippo_self'));
    n := n + 1;
  end loop;
  perform public.post_join_set_status_i(p_user, 'dependents', 0, case when n = 0 then 'none' else 'submitted' end, v_actor, 'status_changed', '本人提出 ' || n || ' 人（' || coalesce(p_via, 'nippo_self') || '）', v_src);
  update employee_tax_settings set dependents_count = n, dependent_form_submitted = true, updated_at = now() where user_id = p_user;
  if v_wf is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, after)
    values (v_wf, null, 'dependents.submitted', v_actor, case when auth.uid() is null then 'system' else 'nippo' end,
            jsonb_build_object('count', n, 'relationships', (select jsonb_agg(relationship) from employee_dependents where user_id = p_user and is_active and source <> 'smaregi_snapshot'), 'via', p_via));
  end if;
  return jsonb_build_object('ok', true, 'workflow_id', v_wf, 'count', n, 'required', v_eff -> 'required', 'deadline', v_eff -> 'deadline');
end $$;
grant execute on function public.onboarding_save_dependents(uuid, jsonb, text, uuid) to authenticated, service_role;

-- 本部: 「不要」にする（year_end は年度つき）
create or replace function public.onboarding_skip_post_join(p_user uuid, p_kind text, p_actor uuid default null, p_year integer default null, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; v_year int;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_kind not in ('year_end', 'dependents') then raise exception '種類が不正です'; end if;
  v_year := case when p_kind = 'dependents' then 0 else coalesce(p_year, public.post_join_year_default()) end;
  perform public.post_join_set_status_i(p_user, p_kind, v_year, 'skipped', v_actor, 'skipped', coalesce(p_reason, '本部が不要と確認'));
  if p_kind = 'year_end' then update employee_year_end set sync_status = 'skipped', updated_at = now() where user_id = p_user and target_year = v_year; end if;
  return jsonb_build_object('ok', true, 'target_year', v_year);
end $$;
grant execute on function public.onboarding_skip_post_join(uuid, text, uuid, integer, text) to authenticated, service_role;

-- 本部の承認（方針⑦: 承認後にスマレジへ）。submitted（または error の再承認）→ approved
create or replace function public.onboarding_post_join_approve(p_user uuid, p_track text, p_year integer, p_actor uuid default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_actor uuid; v_year int; v_status text; v_n int;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_track not in ('dependents','year_end') then raise exception 'track が不正です'; end if;
  v_year := case when p_track = 'dependents' then 0 else coalesce(p_year, public.post_join_year_default()) end;
  select status into v_status from employee_post_join_status where user_id = p_user and track = p_track and target_year = v_year;
  if v_status is null or v_status not in ('submitted','error','approved') then
    return jsonb_build_object('ok', false, 'error', '提出待ちではありません（状態: ' || coalesce(v_status, '未提出') || '）');
  end if;
  perform public.post_join_set_status_i(p_user, p_track, v_year, 'approved', v_actor, 'approved', p_note);
  if p_track = 'dependents' then select count(*) into v_n from employee_dependents where user_id = p_user and is_active and source <> 'smaregi_snapshot'; else v_n := 1; end if;
  return jsonb_build_object('ok', true, 'status', 'approved', 'target_year', v_year, 'can_enqueue', v_n > 0);
end $$;
grant execute on function public.onboarding_post_join_approve(uuid, text, integer, uuid, text) to authenticated, service_role;

-- 差し戻し（本人に直してもらう）: submitted/approved → pending。提出内容は残す
create or replace function public.onboarding_post_join_reject(p_user uuid, p_track text, p_year integer, p_actor uuid default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_actor uuid; v_year int;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_track not in ('dependents','year_end') then raise exception 'track が不正です'; end if;
  v_year := case when p_track = 'dependents' then 0 else coalesce(p_year, public.post_join_year_default()) end;
  perform public.post_join_set_status_i(p_user, p_track, v_year, 'pending', v_actor, 'rejected', coalesce(p_note, '本部が差し戻し'));
  return jsonb_build_object('ok', true, 'status', 'pending', 'target_year', v_year);
end $$;
grant execute on function public.onboarding_post_join_reject(uuid, text, integer, uuid, text) to authenticated, service_role;

-- -------------------------------------------------------------
-- 8) スマレジへ（承認後のみ）
-- -------------------------------------------------------------
create or replace function public.onboarding_enqueue_year_end(p_workflow uuid, p_actor uuid default null, p_year integer default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; wf onboarding_workflows%rowtype; y employee_year_end%rowtype; v_job jsonb; v_year int; v_status text;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into wf from onboarding_workflows where id = p_workflow; if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
  v_year := coalesce(p_year, public.post_join_year_default());
  select * into y from employee_year_end where user_id = wf.user_id and target_year = v_year; if y.user_id is null then return jsonb_build_object('ok', false, 'error', '年末調整（' || v_year || ' 年度）の提出がまだありません'); end if;
  select status into v_status from employee_post_join_status where user_id = wf.user_id and track = 'year_end' and target_year = v_year;
  if coalesce(v_status, '') not in ('approved','queued','error') then return jsonb_build_object('ok', false, 'error', '本部の承認が先です（状態: ' || coalesce(v_status, '未提出') || '）'); end if;
  v_job := ui_job_enqueue(p_workflow, 'smaregi_year_end', jsonb_build_object('target_year', v_year,
    'household_header_name', y.household_header_name, 'household_header_relationship', y.household_header_relationship, 'spouse_flag', y.spouse_flag,
    'estimate_income', y.estimate_income, 'retirement_income', y.retirement_income, 'handicapped_division', y.handicapped_division,
    'widow_division2', y.widow_division2, 'widow_division', y.widow_division, 'student_flag', y.student_flag,
    'salary_payment_report_collection_division', y.salary_payment_report_collection_division), v_actor, false);
  if coalesce(v_job ->> 'ok', 'false') = 'true' then
    update employee_year_end set ui_job_id = (v_job ->> 'job_id')::uuid, sync_status = 'queued', confirmed_by = v_actor, confirmed_at = now(), updated_at = now() where user_id = wf.user_id and target_year = v_year;
    update employee_post_join_status set status = 'queued', updated_at = now() where user_id = wf.user_id and track = 'year_end' and target_year = v_year;
  else
    update employee_year_end set sync_status = 'manual', sync_error = v_job ->> 'error', confirmed_by = v_actor, confirmed_at = now(), updated_at = now() where user_id = wf.user_id and target_year = v_year;
  end if;
  insert into onboarding_events(workflow_id, kind, actor_id, via, payload) values (p_workflow, 'year_end.enqueued', v_actor, 'slack', v_job || jsonb_build_object('target_year', v_year));
  return jsonb_build_object('ok', true, 'job', v_job, 'target_year', v_year);
end $$;
grant execute on function public.onboarding_enqueue_year_end(uuid, uuid, integer) to authenticated, service_role;

-- 扶養親族をスマレジへ（承認後のみ）: 有効行の配列 → ジョブ。verify に氏名・続柄・生年月日（照合用。Slack には出さない）
create or replace function public.onboarding_enqueue_dependents(p_workflow uuid, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; wf onboarding_workflows%rowtype; v_rows jsonb; v_job jsonb; v_status text;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into wf from onboarding_workflows where id = p_workflow; if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
  select status into v_status from employee_post_join_status where user_id = wf.user_id and track = 'dependents' and target_year = 0;
  if coalesce(v_status, '') not in ('approved','queued','error') then return jsonb_build_object('ok', false, 'error', '本部の承認が先です（状態: ' || coalesce(v_status, '未提出') || '）'); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'name', d.name, 'kana', d.kana, 'relationship', d.relationship, 'birthday', d.birthday, 'living_together_division', d.living_together_division,
                                               'post_code', d.post_code, 'address', d.address, 'estimate_income', d.estimate_income, 'retirement_income', d.retirement_income, 'handicapped_division', d.handicapped_division) order by d.created_at), '[]'::jsonb)
    into v_rows from employee_dependents d where d.user_id = wf.user_id and d.is_active and d.source <> 'smaregi_snapshot';
  if jsonb_array_length(v_rows) = 0 then return jsonb_build_object('ok', false, 'error', '扶養親族の提出がありません（扶養なしの人は反映不要）'); end if;
  v_job := ui_job_enqueue(p_workflow, 'smaregi_dependents', jsonb_build_object('rows', v_rows,
    'verify', (select jsonb_agg(jsonb_build_object('name', r ->> 'name', 'relationship', r ->> 'relationship', 'birthday', r ->> 'birthday')) from jsonb_array_elements(v_rows) r)), v_actor, false);
  if coalesce(v_job ->> 'ok', 'false') = 'true' then
    update employee_dependents set ui_job_id = (v_job ->> 'job_id')::uuid, updated_at = now() where user_id = wf.user_id and is_active and source <> 'smaregi_snapshot';
    update employee_post_join_status set status = 'queued', updated_at = now() where user_id = wf.user_id and track = 'dependents' and target_year = 0;
  end if;
  insert into onboarding_events(workflow_id, kind, actor_id, via, payload) values (p_workflow, 'dependents.enqueued', v_actor, 'slack', jsonb_build_object('count', jsonb_array_length(v_rows), 'job', v_job));
  return jsonb_build_object('ok', true, 'count', jsonb_array_length(v_rows), 'job', v_job);
end $$;
grant execute on function public.onboarding_enqueue_dependents(uuid, uuid) to authenticated, service_role;

-- 源泉所得税の設定（Slack モーダル＝スマレジと同じ 4 項目・社員/アルバイト共通）→ ジョブ（スイッチ OFF なら manual）
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

-- -------------------------------------------------------------
-- 9) 既存従業員: スマレジの内容を 1 人ずつ取り込む（snapshot）。self 行・提出状況は触らない（方針⑥）
-- -------------------------------------------------------------
create or replace function public.post_join_import_snapshot(p_user uuid, p_year_end jsonb, p_dependents jsonb, p_actor uuid default null, p_year integer default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; v_year int; r jsonb; n int := 0; v_rel int;
begin
  if auth.uid() is not null then v_actor := public.onboarding_resolve_actor(null);
  elsif public.onboarding_is_service() then v_actor := p_actor;
  else raise exception '認証が必要です'; end if;
  v_year := coalesce(p_year, public.post_join_year_default());
  if p_year_end is not null and jsonb_typeof(p_year_end) = 'object' then
    insert into employee_year_end_snapshot(user_id, target_year, data, fetched_at, fetched_by) values (p_user, v_year, p_year_end, now(), v_actor)
    on conflict (user_id, target_year) do update set data = excluded.data, fetched_at = now(), fetched_by = excluded.fetched_by;
  end if;
  if p_dependents is not null and jsonb_typeof(p_dependents) = 'array' then
    delete from employee_dependents where user_id = p_user and source = 'smaregi_snapshot';
    for r in select * from jsonb_array_elements(p_dependents) loop
      if coalesce(trim(r ->> 'name'), '') = '' then continue; end if;
      v_rel := nullif(r ->> 'relationship', '')::int;
      insert into employee_dependents(user_id, name, kana, relationship, birthday, living_together_division, estimate_income, handicapped_division, is_active, source, submitted_at, submitted_via)
      values (p_user, left(trim(r ->> 'name'), 50), left(coalesce(r ->> 'kana', ''), 50), coalesce(v_rel, 99), nullif(r ->> 'birthday', '')::date, coalesce(nullif(r ->> 'living_together_division', '')::int, 1),
              coalesce(nullif(r ->> 'estimate_income', '')::int, 0), coalesce(nullif(r ->> 'handicapped_division', '')::int, 1), false, 'smaregi_snapshot', now(), 'smaregi_snapshot');
      n := n + 1;
    end loop;
  end if;
  insert into post_join_policy_history(user_id, track, target_year, kind, after, actor_id) values (p_user, null, v_year, 'snapshot_imported', jsonb_build_object('year_end', p_year_end is not null, 'dependents', n), v_actor);
  return jsonb_build_object('ok', true, 'target_year', v_year, 'dependents', n);
end $$;
revoke all on function public.post_join_import_snapshot(uuid, jsonb, jsonb, uuid, integer) from public, anon;
grant execute on function public.post_join_import_snapshot(uuid, jsonb, jsonb, uuid, integer) to authenticated, service_role;

-- -------------------------------------------------------------
-- 10) 一覧・リマインド
-- -------------------------------------------------------------
-- 本人 / 本部: トラックごとの実効ポリシー＋状態＋提出内容の要約＋snapshot の有無＋履歴
create or replace function public.onboarding_post_join_overview(p_user uuid, p_year integer default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_year int; ye jsonb; dp jsonb; v_rules jsonb; v_hist jsonb; v_class text;
begin
  perform public.onboarding_self_or_hq(p_user, null);
  v_year := coalesce(p_year, public.post_join_year_default());
  ye := public.post_join_effective_i(p_user, 'year_end', v_year) || jsonb_build_object(
          'data', (select to_jsonb(y) from employee_year_end y where y.user_id = p_user and y.target_year = v_year),
          'snapshot', (select jsonb_build_object('data', s.data, 'fetched_at', s.fetched_at) from employee_year_end_snapshot s where s.user_id = p_user and s.target_year = v_year),
          'years', (select coalesce(jsonb_agg(y.target_year order by y.target_year desc), '[]'::jsonb) from employee_year_end y where y.user_id = p_user));
  dp := public.post_join_effective_i(p_user, 'dependents', 0) || jsonb_build_object(
          'rows', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at), '[]'::jsonb) from employee_dependents d where d.user_id = p_user and d.is_active and d.source <> 'smaregi_snapshot'),
          'snapshot_rows', (select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at), '[]'::jsonb) from employee_dependents d where d.user_id = p_user and d.source = 'smaregi_snapshot'),
          'synced', (select count(*) from employee_dependents d where d.user_id = p_user and d.is_active and d.smaregi_synced_at is not null));
  v_class := ye ->> 'class';
  v_rules := (select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) from post_join_rules r where r.class = v_class);
  v_hist := (select coalesce(jsonb_agg(to_jsonb(h) order by h.created_at desc), '[]'::jsonb) from (select * from post_join_policy_history h where h.user_id = p_user order by h.created_at desc limit 30) h);
  return jsonb_build_object('user_id', p_user, 'target_year', v_year, 'class', v_class, 'year_end', ye, 'dependents', dp, 'rules', v_rules, 'history', v_hist,
                            'legal_note', '「任意」は社内運用上の扱いです。税法上の提出・申告の義務を免除するものではありません');
end $$;
grant execute on function public.onboarding_post_join_overview(uuid, integer) to authenticated, service_role;

-- リマインド対象（方針⑤: 必須かつ未完了だけ。期限前は remind_interval_days・期限後は after_deadline の間隔。入社後 p_start_days 日未満は対象外）
create or replace function public.onboarding_post_join_targets(p_now timestamptz default now(), p_start_days integer default 3)
returns table(user_id uuid, workflow_id uuid, name text, hire_date date, track text, target_year integer, deadline date, required_source text, class text,
              last_reminded_at timestamptz, remind_count integer, interval_days integer, has_slack boolean, has_line boolean)
language plpgsql security definer set search_path to 'public' stable
as $$
declare u record; t text; e jsonb; v_year int; v_int int; v_last timestamptz; v_deadline date;
begin
  if not (public.onboarding_is_service() or public.hq_can_manage()) then raise exception '権限がありません'; end if;
  for u in select x.id, x.name, coalesce(p.hire_date, x.created_at::date) as hire_date, (select w.id from onboarding_workflows w where w.user_id = x.id) as wf
             from users x left join employee_profiles p on p.user_id = x.id
            where x.is_active and x.role in ('AL','SHAIN','TENCHO','TEAM','HQ','CEO') order by x.created_at loop
    if u.hire_date > (p_now at time zone 'Asia/Tokyo')::date - p_start_days then continue; end if;
    foreach t in array array['dependents','year_end'] loop
      e := public.post_join_effective_i(u.id, t, null);
      if not ((e ->> 'required')::boolean and (e ->> 'remind_enabled')::boolean and (e ->> 'target')::boolean and (e ->> 'form_enabled')::boolean and (e ->> 'status') = 'pending') then continue; end if;
      v_year := (e ->> 'target_year')::int; v_deadline := nullif(e ->> 'deadline', '')::date;
      v_int := case when v_deadline is not null and (p_now at time zone 'Asia/Tokyo')::date > v_deadline then (e ->> 'remind_interval_after_deadline_days')::int else (e ->> 'remind_interval_days')::int end;
      v_last := nullif(e ->> 'last_reminded_at', '')::timestamptz;
      if v_last is not null and v_last + make_interval(days => v_int) > p_now then continue; end if;
      user_id := u.id; workflow_id := u.wf; name := u.name; hire_date := u.hire_date; track := t; target_year := v_year; deadline := v_deadline; required_source := e ->> 'source_of_required'; class := e ->> 'class';
      last_reminded_at := v_last; remind_count := (e ->> 'remind_count')::int; interval_days := v_int;
      has_slack := exists(select 1 from user_slack us where us.user_id = u.id); has_line := exists(select 1 from users z where z.id = u.id and z.line_user_id is not null);
      return next;
    end loop;
  end loop;
end $$;
grant execute on function public.onboarding_post_join_targets(timestamptz, integer) to authenticated, service_role;

-- リマインドを記録（EF から・トラックと年度つき）
create or replace function public.onboarding_post_join_reminded(p_user uuid, p_track text default 'dependents', p_year integer default 0)
returns void language sql security definer set search_path to 'public' as $$
  insert into employee_post_join_status(user_id, track, target_year, workflow_id, last_reminded_at, remind_count)
  values (p_user, p_track, p_year, (select id from onboarding_workflows where user_id = p_user), now(), 1)
  on conflict (user_id, track, target_year) do update set last_reminded_at = now(), remind_count = employee_post_join_status.remind_count + 1, updated_at = now();
$$;
revoke all on function public.onboarding_post_join_reminded(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.onboarding_post_join_reminded(uuid, text, integer) to service_role;

-- 必須なのに未提出の人（本部が案内する一覧。自動通知はしない）。recent_class_change=最近 90 日に雇用区分が変わった人（方針④の「本人に案内できる」）
create or replace view public.post_join_required_pending_v as
select u.id as user_id, u.name, u.role, public.post_join_class(u.role) as class, t.track,
       (e ->> 'target_year')::int as target_year, (e ->> 'deadline')::date as deadline, e ->> 'source_of_required' as required_source, e ->> 'status' as status,
       exists(select 1 from post_join_policy_history h where h.user_id = u.id and h.kind = 'class_changed' and h.created_at > now() - interval '90 days') as recent_class_change
  from users u cross join (values ('dependents'), ('year_end')) as t(track)
  cross join lateral public.post_join_effective_i(u.id, t.track, null) as e
 where u.is_active and (e ->> 'required')::boolean and (e ->> 'status') = 'pending' and (public.onboarding_is_service() or public.hq_can_manage());
grant select on public.post_join_required_pending_v to authenticated, service_role;

-- -------------------------------------------------------------
-- 11) 事業所（v1 のまま）
-- -------------------------------------------------------------
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
  select coalesce(i.postal_code, ''), coalesce(i.address, '') || coalesce(i.building, ''), coalesce(i.phone, '') into v_post, v_addr, v_phone from info.stores i where i.hub_store_id = s.id limit 1;
  v_addr := coalesce(v_addr, ''); v_post := coalesce(v_post, ''); v_phone := coalesce(v_phone, '');
  for i in 1..47 loop if v_addr like prefs[i] || '%' then v_pref := i; v_addr := substr(v_addr, length(prefs[i]) + 1); exit; end if; end loop;
  v_payload := jsonb_build_object('store_id', s.id, 'contract_id', p_contract, 'store_name', left(s.name, 50), 'kana', left(coalesce(s.name, ''), 50), 'abbr', left(coalesce(s.display_name, s.name), 15),
                                  'post_code', v_post, 'prefecture_code', v_pref, 'address', left(v_addr, 255), 'phone', v_phone);
  v_job := ui_job_enqueue(null, 'smaregi_store', v_payload, v_actor, false);
  return jsonb_build_object('ok', coalesce(v_job ->> 'ok', 'false') = 'true', 'already_mapped', false, 'job', v_job, 'error', v_job ->> 'error');
end $$;
grant execute on function public.smaregi_store_create_request(uuid, text, uuid) to authenticated, service_role;

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
-- 12) ビュー
-- -------------------------------------------------------------
create or replace view public.onboarding_post_join_v as
select u.id as user_id, w.id as workflow_id, u.name as user_name, w.hire_date, w.status as workflow_status,
       public.post_join_effective_i(u.id, 'year_end', null) as year_end,
       public.post_join_effective_i(u.id, 'dependents', 0) as dependents,
       (select count(*) from employee_dependents d where d.user_id = u.id and d.is_active and d.source <> 'smaregi_snapshot') as dependents_count,
       (select count(*) from employee_dependents d where d.user_id = u.id and d.is_active and d.smaregi_synced_at is not null) as dependents_synced
  from onboarding_workflows w join users u on u.id = w.user_id;
alter view public.onboarding_post_join_v set (security_invoker = true);
grant select on public.onboarding_post_join_v to authenticated, service_role;

-- onboarding_workflow_v 新版（year_end / dependents 列: 実効ポリシー＋状態＋件数。Slack の親メッセージ用）。列順の都合で drop → create（依存ビューなし・grant を再付与）
drop view if exists public.onboarding_workflow_v;
create view public.onboarding_workflow_v as
select w.*, u.name as user_name, u.email as user_email, u.is_active as user_active,
       (select string_agg(s.name, '・' order by s.sort_order) from stores s where s.id = any(w.store_ids)) as store_names,
       (select jsonb_object_agg(i.item_key, jsonb_build_object('state', i.state, 'attempts', i.attempts, 'last_error', i.last_error, 'payload', i.payload, 'completed_at', i.completed_at, 'completion_source', i.completion_source))
          from onboarding_items i where i.workflow_id = w.id) as items,
       (select c.label from smaregi_contracts c where c.contract_id = w.contract_id limit 1) as contract_label,
       case when w.user_id is null then null else public.post_join_effective_i(w.user_id, 'year_end', null)
            || jsonb_build_object('sync_status', (select y.sync_status from employee_year_end y where y.user_id = w.user_id and y.target_year = public.post_join_year_default()),
                                  'verified_at', (select y.verified_at from employee_year_end y where y.user_id = w.user_id and y.target_year = public.post_join_year_default())) end as year_end,
       case when w.user_id is null then null else public.post_join_effective_i(w.user_id, 'dependents', 0)
            || jsonb_build_object('count', (select count(*) from employee_dependents d where d.user_id = w.user_id and d.is_active and d.source <> 'smaregi_snapshot'),
                                  'synced', (select count(*) from employee_dependents d where d.user_id = w.user_id and d.is_active and d.smaregi_synced_at is not null),
                                  'relationships', (select jsonb_agg(d.relationship order by d.created_at) from employee_dependents d where d.user_id = w.user_id and d.is_active and d.source <> 'smaregi_snapshot')) end as dependents
  from onboarding_workflows w left join users u on u.id = w.user_id;
alter view public.onboarding_workflow_v set (security_invoker = true);
grant select on public.onboarding_workflow_v to authenticated, service_role;

-- -------------------------------------------------------------
-- 13) 設定とリマインドの cron 用関数（schedule は承認後に手で）
-- -------------------------------------------------------------
update app_settings
   set value = value || jsonb_build_object(
     'post_join_remind_enabled', coalesce((value ->> 'post_join_remind_enabled')::boolean, false),
     'post_join_remind_days', coalesce((value ->> 'post_join_remind_days')::int, 3))
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

-- -------------------------------------------------------------
-- v2 追補（2026-11-09）: 「スマレジの内容を取り込む」の依頼（本人 or 本部）。取り込み自体は Slack の 🔎（EF post_join_snapshot）で 1 人ずつ行う。履歴に残すだけ
-- -------------------------------------------------------------
create or replace function public.post_join_request_snapshot(p_user uuid, p_year integer default null, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; v_year integer;
begin
  if auth.uid() is not null then
    if auth.uid() <> p_user and not public.hq_can_manage() then raise exception '権限がありません'; end if;
    v_actor := auth.uid();
  elsif public.onboarding_is_service() then v_actor := p_actor;
  else raise exception '認証が必要です'; end if;
  v_year := coalesce(p_year, public.post_join_year_default());
  insert into post_join_policy_history(user_id, track, target_year, kind, after, reason, actor_id)
  values (p_user, 'year_end', v_year, 'snapshot_requested', jsonb_build_object('requested_by', case when v_actor = p_user then 'self' else 'hq' end), 'スマレジの登録内容の取り込みを依頼（Slack の 🔎 で本部が実行）', v_actor);
  return jsonb_build_object('ok', true, 'note', '取り込みは本部が Slack の「🔎 スマレジと比較」で 1 人ずつ行います');
end $$;
grant execute on function public.post_join_request_snapshot(uuid, integer, uuid) to authenticated, service_role;
