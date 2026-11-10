-- =============================================================
-- 入社登録 Phase 6 v3 追補（2026-11-10・★ 本番未適用。適用は中山さんの承認後）
--   ① 自動リマインドの安全対策: 新規入社者と既存従業員を区別。既存従業員は「未提出」だけでは通知しない。
--      本部が対象者／対象グループを登録 → マスター・社長が承認した「対象リスト」に入っている人だけ通知対象。
--      1 回の送信人数に上限（post_join_max_per_run）。超えたら誰にも送らない。dry-run 画面用の一覧と文面を返す関数。
--   ⑤ 社内期限（internal_deadline＝リマインド・必須管理に使う）と法定期限（legal_deadline＝参考表示のみ）を別の概念に。
--      社内期限は月末（給与締め日）を基本にし、本部が個別に変更できる（post_join_set_override の deadline）。
--   既存データ: post_join_rules の 4 行を更新（下の「本番適用時に変わる既存行」）。従業員の提出データ・状態は変えない。
--   切り戻し: 2026-11-10_post_join_remind_scope_rollback.sql（データ保全版）
-- =============================================================

-- -------------------------------------------------------------
-- 1) ⑤ 標準ルールに「法定期限（参考）」の列。社内期限は月末を基本に
-- -------------------------------------------------------------
alter table public.post_join_rules add column if not exists legal_deadline_basis text
  check (legal_deadline_basis is null or legal_deadline_basis in ('first_pay_day_prev','year_last_pay_prev'));   -- 最初の給与支払日の前日／その年最後の給与支払日の前日
alter table public.post_join_rules add column if not exists pay_day integer not null default 15 check (pay_day between 1 and 31);            -- 給与支払日（翌月 15 日払い）
alter table public.post_join_rules add column if not exists pay_month_offset integer not null default 1 check (pay_month_offset between 0 and 2);  -- 締め月の何か月後に支払うか
alter table public.post_join_rules add column if not exists legal_note text;                                    -- 法定期限についての注記（参考。システムは法的判断をしない）

-- ★ 本番適用時に変わる既存行（post_join_rules 4 行。履歴トリガーで post_join_policy_history に rule_changed が 4 件入る）:
--   SHAIN×dependents: deadline_days 14 → null（社内期限＝入社後最初の月末。payroll_closing_day 31・lead 0 はそのまま）／法定期限の列を設定
--   AL×dependents   : payroll_closing_day null → 31（任意なので表示用）／法定期限の列を設定
--   SHAIN×year_end・AL×year_end: 法定期限の列を設定（deadline_month_day '11-30' はそのまま）
update public.post_join_rules set deadline_days = null, payroll_closing_day = coalesce(payroll_closing_day, 31),
       legal_deadline_basis = 'first_pay_day_prev',
       legal_note = '扶養控除等申告書は、その年最初の給与の支払を受ける日の前日（中途入社は入社後最初の給与支払日の前日）までに提出するものとされています。祝日等で支払日が前倒しになる場合があります。正確な期限は税理士・所轄税務署に確認してください',
       note = '社員: 扶養フォームは社内運用上 提出必須。社内期限＝入社後最初の月末（給与の締め日。末日締め・翌月 15 日払い）。本部が個別に変更可。法定期限（参考）は別管理',
       updated_at = now()
 where class = 'SHAIN' and track = 'dependents';
update public.post_join_rules set payroll_closing_day = coalesce(payroll_closing_day, 31),
       legal_deadline_basis = 'first_pay_day_prev',
       legal_note = '扶養控除等申告書は、その年最初の給与の支払を受ける日の前日（中途入社は入社後最初の給与支払日の前日）までに提出するものとされています。社内システムで「任意」にしていても、この提出義務が無くなるわけではありません。正確な期限は税理士・所轄税務署に確認してください',
       note = 'アルバイト: 利用可・初期は任意・リマインドなし（本部が個別に必須へ変更可）。社内期限（表示用）＝入社後最初の月末。法定期限（参考）は別管理',
       updated_at = now()
 where class = 'AL' and track = 'dependents';
update public.post_join_rules set legal_deadline_basis = 'year_last_pay_prev',
       legal_note = '年末調整の申告書類は、その年最後の給与の支払を受ける日の前日までに提出するものとされています（12 月の給与支払日が基準。祝日等で前倒しあり）。正確な期限は税理士・所轄税務署に確認してください',
       updated_at = now()
 where track = 'year_end';

-- 法定期限（参考）の計算。祝日の前倒しは考慮しない（注記で案内）
create or replace function public.post_join_legal_deadline(p_basis text, p_hire date, p_year integer, p_closing_day integer, p_pay_day integer, p_pay_month_offset integer)
returns date language plpgsql immutable as $$
declare v_month date; v_close date; v_pay_month date; v_pay date;
begin
  if p_basis = 'first_pay_day_prev' then
    if p_hire is null then return null; end if;
    -- 入社日が入る締め期間の締め日 → その支払月の支払日 → 前日
    v_month := date_trunc('month', p_hire)::date;
    v_close := least((v_month + interval '1 month' - interval '1 day')::date, v_month + (coalesce(p_closing_day, 31) - 1));
    if v_close < p_hire then v_month := (v_month + interval '1 month')::date; end if;
    v_pay_month := (v_month + make_interval(months => coalesce(p_pay_month_offset, 1)))::date;
    v_pay := least((v_pay_month + interval '1 month' - interval '1 day')::date, v_pay_month + (coalesce(p_pay_day, 15) - 1));
    return v_pay - 1;
  elsif p_basis = 'year_last_pay_prev' then
    if p_year is null or p_year = 0 then return null; end if;
    v_pay_month := make_date(p_year, 12, 1);
    v_pay := least((v_pay_month + interval '1 month' - interval '1 day')::date, v_pay_month + (coalesce(p_pay_day, 15) - 1));
    return v_pay - 1;
  end if;
  return null;
end $$;

-- 実効ポリシー 新版: 既存キー（deadline＝社内期限 ほか）はそのまま。internal_deadline / legal_deadline / legal_deadline_basis / legal_deadline_note を追加
create or replace function public.post_join_effective_i(p_user uuid, p_track text, p_year integer default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_role text; v_class text; r post_join_rules%rowtype; o post_join_overrides%rowtype; s employee_post_join_status%rowtype;
        v_year int; v_hire date; v_deadline date; v_payroll date; v_deadline_reason text; v_required bool; v_remind bool; v_enabled bool; v_invite bool; v_target bool; v_src text := 'rule'; v_status text;
        v_legal date;
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
  -- 社内期限（扶養）: 月末（給与締め日 − リード日数。入社から 2 日未満なら次の締め日）が基本。deadline_days があれば早い方
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
  -- 個別変更は社内期限だけを変える（法定期限は変えない）
  if o.deadline is not null then v_deadline := o.deadline; v_deadline_reason := 'override'; end if;
  if o.user_id is not null then v_src := 'override'; end if;
  -- 法定期限（参考表示のみ。リマインドや必須判定には使わない）
  v_legal := public.post_join_legal_deadline(r.legal_deadline_basis, v_hire, v_year, r.payroll_closing_day, r.pay_day, r.pay_month_offset);
  select * into s from employee_post_join_status where user_id = p_user and track = p_track and target_year = v_year;
  v_status := coalesce(s.status, case when not v_target then 'not_target' else 'pending' end);
  return jsonb_build_object('user_id', p_user, 'track', p_track, 'target_year', v_year, 'class', v_class, 'role', v_role, 'hire_date', v_hire,
    'form_enabled', v_enabled, 'invite_on_join', v_invite, 'target', v_target, 'required', v_required, 'remind_enabled', v_remind, 'deadline', v_deadline, 'deadline_reason', v_deadline_reason,
    'source_of_required', v_src, 'override_reason', o.reason, 'status', v_status, 'submitted_at', s.submitted_at, 'approved_at', s.approved_at,
    'last_reminded_at', s.last_reminded_at, 'remind_count', coalesce(s.remind_count, 0),
    'remind_interval_days', coalesce(r.remind_interval_days, 3), 'remind_interval_after_deadline_days', coalesce(r.remind_interval_after_deadline_days, 1),
    'legal_note', '「任意」は社内運用上の扱いです。税法上の提出・申告の義務を免除するものではありません')
    || jsonb_build_object('internal_deadline', v_deadline, 'legal_deadline', v_legal, 'legal_deadline_basis', r.legal_deadline_basis, 'legal_deadline_note', r.legal_note);
end $$;
revoke all on function public.post_join_effective_i(uuid, text, integer) from public, anon;
grant execute on function public.post_join_effective_i(uuid, text, integer) to authenticated, service_role;

-- 標準ルールの変更 新版: patch に legal_deadline_basis / pay_day / pay_month_offset / legal_note を追加（他は従来どおり）
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
    legal_deadline_basis = case when p_patch ? 'legal_deadline_basis' then nullif(p_patch ->> 'legal_deadline_basis', '') else legal_deadline_basis end,
    pay_day = coalesce((p_patch ->> 'pay_day')::int, pay_day),
    pay_month_offset = coalesce((p_patch ->> 'pay_month_offset')::int, pay_month_offset),
    legal_note = case when p_patch ? 'legal_note' then nullif(p_patch ->> 'legal_note', '') else legal_note end,
    note = p_reason, updated_by = v_actor, updated_at = now()
  where class = p_class and track = p_track;
  if not found then raise exception 'ルールが見つかりません'; end if;
  return (select to_jsonb(r) from post_join_rules r where class = p_class and track = p_track);
end $$;
grant execute on function public.post_join_set_rule(text, text, jsonb, text, uuid) to authenticated, service_role;

-- -------------------------------------------------------------
-- 2) ① 対象リスト（既存従業員を通知対象にするための、明示的な登録と承認）
-- -------------------------------------------------------------
create table if not exists public.post_join_remind_batches (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  track         text not null check (track in ('dependents','year_end','both')),
  target_year   integer,                                   -- 年末調整の対象年度（null=その時点の既定年度）
  filter        jsonb,                                     -- 登録時の条件メモ（class / store_ids / roles）。メンバーは登録時点で行に展開する
  note          text,
  status        text not null default 'draft' check (status in ('draft','approved','cancelled','closed')),
  created_by    uuid,
  created_at    timestamptz not null default now(),
  approved_by   uuid,
  approved_at   timestamptz,
  cancelled_by  uuid,
  cancelled_at  timestamptz,
  cancel_reason text
);
create table if not exists public.post_join_remind_members (
  batch_id    uuid not null references public.post_join_remind_batches(id) on delete cascade,
  user_id     uuid not null references public.users(id) on delete cascade,
  added_by    uuid,
  added_at    timestamptz not null default now(),
  removed_at  timestamptz,
  removed_by  uuid,
  primary key (batch_id, user_id)
);
create index if not exists post_join_remind_members_user_idx on public.post_join_remind_members(user_id) where removed_at is null;
alter table public.post_join_remind_batches enable row level security;
alter table public.post_join_remind_members enable row level security;
drop policy if exists post_join_remind_batches_read on public.post_join_remind_batches;
create policy post_join_remind_batches_read on public.post_join_remind_batches for select to authenticated using (public.hq_can_manage());
drop policy if exists post_join_remind_members_read on public.post_join_remind_members;
create policy post_join_remind_members_read on public.post_join_remind_members for select to authenticated using (public.hq_can_manage());

-- 履歴の種類を追加（対象リストの登録・承認・取り消し・メンバー除外・リマインド設定の変更）
alter table public.post_join_policy_history drop constraint if exists post_join_policy_history_kind_check;
alter table public.post_join_policy_history add constraint post_join_policy_history_kind_check
  check (kind in ('rule_changed','override_set','override_cleared','class_changed','status_changed','approved','rejected','skipped','choice','snapshot_imported','snapshot_requested',
                  'remind_batch_created','remind_batch_approved','remind_batch_cancelled','remind_member_removed','remind_settings_changed'));

-- 設定: 新規入社者とみなす基準日（ワークフロー作成日がこの日以降）・1 回の送信人数の上限
update app_settings
   set value = value || jsonb_build_object(
     'post_join_new_hire_from', coalesce(value ->> 'post_join_new_hire_from', '2026-11-09'),
     'post_join_max_per_run', coalesce((value ->> 'post_join_max_per_run')::int, 10))
 where key = 'onboarding_alerts';

-- 対象リストの登録（本部）。p_user_ids（個別指定）か p_filter {class:'SHAIN'|'AL', store_ids:[uuid], roles:[text]}（グループ指定。登録時点の該当者をメンバー行に展開）
create or replace function public.post_join_remind_batch_create(p_title text, p_track text, p_year integer, p_user_ids uuid[], p_filter jsonb, p_note text default null, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_actor uuid; v_batch uuid; v_n int; v_ids uuid[];
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if coalesce(trim(p_title), '') = '' then raise exception '対象リストの名前を入れてください'; end if;
  if p_track not in ('dependents','year_end','both') then raise exception 'track が不正です'; end if;
  if (p_user_ids is null or cardinality(p_user_ids) = 0) and (p_filter is null or p_filter = '{}'::jsonb) then raise exception '対象者（個別）か対象グループ（条件）を指定してください'; end if;
  select array_agg(distinct x.id) into v_ids from (
    select u.id from users u where u.is_active and p_user_ids is not null and u.id = any(p_user_ids)
    union
    select u.id from users u
     where u.is_active and p_filter is not null and p_filter <> '{}'::jsonb
       and (p_filter ? 'class' or p_filter ? 'store_ids' or p_filter ? 'roles')
       and (not (p_filter ? 'class') or public.post_join_class(u.role) = p_filter ->> 'class')
       and (not (p_filter ? 'roles') or u.role in (select jsonb_array_elements_text(p_filter -> 'roles')))
       and (not (p_filter ? 'store_ids') or exists (select 1 from user_stores us where us.user_id = u.id and us.store_id::text in (select jsonb_array_elements_text(p_filter -> 'store_ids'))))
  ) x;
  v_n := coalesce(cardinality(v_ids), 0);
  if v_n = 0 then raise exception '該当する従業員がいません'; end if;
  insert into post_join_remind_batches(title, track, target_year, filter, note, status, created_by)
  values (trim(p_title), p_track, p_year, p_filter, p_note, 'draft', v_actor) returning id into v_batch;
  insert into post_join_remind_members(batch_id, user_id, added_by) select v_batch, unnest(v_ids), v_actor;
  insert into post_join_policy_history(track, target_year, kind, after, reason, actor_id)
  values (case when p_track = 'both' then null else p_track end, p_year, 'remind_batch_created', jsonb_build_object('batch_id', v_batch, 'title', trim(p_title), 'members', v_n, 'filter', p_filter), p_note, v_actor);
  return jsonb_build_object('ok', true, 'batch_id', v_batch, 'members', v_n, 'status', 'draft',
    'max_per_run', coalesce((select (value ->> 'post_join_max_per_run')::int from app_settings where key = 'onboarding_alerts'), 10),
    'note', '下書きです。マスターまたは社長が承認するまで通知対象になりません');
end $$;
grant execute on function public.post_join_remind_batch_create(text, text, integer, uuid[], jsonb, text, uuid) to authenticated, service_role;

-- 承認（マスター・社長のみ）
create or replace function public.post_join_remind_batch_approve(p_batch uuid, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_actor uuid; b post_join_remind_batches%rowtype; v_n int;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if not exists (select 1 from users u where u.id = v_actor and (u.is_master or u.role = 'CEO')) then raise exception '対象リストの承認はマスター・社長のみです'; end if;
  select * into b from post_join_remind_batches where id = p_batch for update;
  if b.id is null then raise exception '対象リストが見つかりません'; end if;
  if b.status <> 'draft' then raise exception '下書きの対象リストだけ承認できます（今の状態: %）', b.status; end if;
  select count(*) into v_n from post_join_remind_members where batch_id = p_batch and removed_at is null;
  if v_n = 0 then raise exception 'メンバーがいません'; end if;
  update post_join_remind_batches set status = 'approved', approved_by = v_actor, approved_at = now() where id = p_batch;
  insert into post_join_policy_history(track, target_year, kind, before, after, actor_id)
  values (case when b.track = 'both' then null else b.track end, b.target_year, 'remind_batch_approved', jsonb_build_object('status', 'draft'), jsonb_build_object('batch_id', p_batch, 'title', b.title, 'members', v_n), v_actor);
  return jsonb_build_object('ok', true, 'batch_id', p_batch, 'status', 'approved', 'members', v_n);
end $$;
grant execute on function public.post_join_remind_batch_approve(uuid, uuid) to authenticated, service_role;

-- 取り消し（本部。下書き・承認済みのどちらも。以後は通知対象から外れる）
create or replace function public.post_join_remind_batch_cancel(p_batch uuid, p_actor uuid default null, p_reason text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_actor uuid; b post_join_remind_batches%rowtype;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into b from post_join_remind_batches where id = p_batch for update;
  if b.id is null then raise exception '対象リストが見つかりません'; end if;
  if b.status not in ('draft','approved') then return jsonb_build_object('ok', true, 'batch_id', p_batch, 'status', b.status, 'already', true); end if;
  update post_join_remind_batches set status = 'cancelled', cancelled_by = v_actor, cancelled_at = now(), cancel_reason = p_reason where id = p_batch;
  insert into post_join_policy_history(track, target_year, kind, before, after, reason, actor_id)
  values (case when b.track = 'both' then null else b.track end, b.target_year, 'remind_batch_cancelled', jsonb_build_object('status', b.status), jsonb_build_object('batch_id', p_batch, 'title', b.title), p_reason, v_actor);
  return jsonb_build_object('ok', true, 'batch_id', p_batch, 'status', 'cancelled');
end $$;
grant execute on function public.post_join_remind_batch_cancel(uuid, uuid, text) to authenticated, service_role;

-- メンバーを 1 人外す（本部）
create or replace function public.post_join_remind_member_remove(p_batch uuid, p_user uuid, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_actor uuid; v_title text;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  update post_join_remind_members set removed_at = now(), removed_by = v_actor where batch_id = p_batch and user_id = p_user and removed_at is null;
  if not found then return jsonb_build_object('ok', true, 'already', true); end if;
  select title into v_title from post_join_remind_batches where id = p_batch;
  insert into post_join_policy_history(user_id, kind, after, actor_id) values (p_user, 'remind_member_removed', jsonb_build_object('batch_id', p_batch, 'title', v_title), v_actor);
  return jsonb_build_object('ok', true, 'batch_id', p_batch, 'user_id', p_user);
end $$;
grant execute on function public.post_join_remind_member_remove(uuid, uuid, uuid) to authenticated, service_role;

-- 一覧（本部。人数つき）
create or replace function public.post_join_remind_batch_list()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not (public.onboarding_is_service() or public.hq_can_manage()) then raise exception '権限がありません'; end if;
  return coalesce((select jsonb_agg(x order by x.created_at desc) from (
    select b.id, b.title, b.track, b.target_year, b.filter, b.note, b.status, b.created_at, b.approved_at, b.cancelled_at, b.cancel_reason,
           (select name from users u where u.id = b.created_by) as created_by_name, (select name from users u where u.id = b.approved_by) as approved_by_name,
           (select count(*) from post_join_remind_members m where m.batch_id = b.id and m.removed_at is null) as members,
           (select count(*) from post_join_remind_members m where m.batch_id = b.id and m.removed_at is not null) as removed
      from post_join_remind_batches b) x), '[]'::jsonb);
end $$;
grant execute on function public.post_join_remind_batch_list() to authenticated, service_role;

-- メンバーの一覧（本部。氏名・区分・店舗・除外済みか）
create or replace function public.post_join_remind_batch_members(p_batch uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not (public.onboarding_is_service() or public.hq_can_manage()) then raise exception '権限がありません'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'name', u.name, 'role', u.role, 'class', public.post_join_class(u.role),
      'store_names', (select string_agg(s.name, '・' order by s.sort_order) from user_stores us join stores s on s.id = us.store_id where us.user_id = u.id),
      'added_at', m.added_at, 'removed_at', m.removed_at) order by u.name)
    from post_join_remind_members m join users u on u.id = m.user_id where m.batch_id = p_batch), '[]'::jsonb);
end $$;
grant execute on function public.post_join_remind_batch_members(uuid) to authenticated, service_role;

-- リマインドの設定変更（マスター・社長のみ・理由必須）。★ 有効化フラグ post_join_remind_enabled はここでは変えられない（承認のうえ別途）
create or replace function public.post_join_remind_settings_set(p_patch jsonb, p_reason text, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_actor uuid; v_before jsonb; v_new jsonb := '{}'::jsonb;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if not exists (select 1 from users u where u.id = v_actor and (u.is_master or u.role = 'CEO')) then raise exception 'リマインド設定の変更はマスター・社長のみです'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception '変更理由を入れてください'; end if;
  if p_patch ? 'post_join_remind_enabled' then raise exception '自動送信の有効化はこの画面からは変更できません（承認のうえ別途）'; end if;
  if p_patch ? 'post_join_new_hire_from' then
    if (p_patch ->> 'post_join_new_hire_from') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception '基準日は YYYY-MM-DD で入れてください'; end if;
    v_new := v_new || jsonb_build_object('post_join_new_hire_from', p_patch ->> 'post_join_new_hire_from');
  end if;
  if p_patch ? 'post_join_max_per_run' then
    if (p_patch ->> 'post_join_max_per_run')::int not between 1 and 200 then raise exception '1 回の上限は 1〜200 人です'; end if;
    v_new := v_new || jsonb_build_object('post_join_max_per_run', (p_patch ->> 'post_join_max_per_run')::int);
  end if;
  if p_patch ? 'post_join_remind_days' then
    if (p_patch ->> 'post_join_remind_days')::int not between 0 and 60 then raise exception '開始日数は 0〜60 日です'; end if;
    v_new := v_new || jsonb_build_object('post_join_remind_days', (p_patch ->> 'post_join_remind_days')::int);
  end if;
  if v_new = '{}'::jsonb then raise exception '変更できる項目がありません'; end if;
  select jsonb_build_object('post_join_new_hire_from', value -> 'post_join_new_hire_from', 'post_join_max_per_run', value -> 'post_join_max_per_run', 'post_join_remind_days', value -> 'post_join_remind_days') into v_before from app_settings where key = 'onboarding_alerts';
  update app_settings set value = value || v_new, updated_at = now(), updated_by = v_actor where key = 'onboarding_alerts';
  insert into post_join_policy_history(kind, before, after, reason, actor_id) values ('remind_settings_changed', v_before, v_new, p_reason, v_actor);
  return jsonb_build_object('ok', true, 'changed', v_new);
end $$;
grant execute on function public.post_join_remind_settings_set(jsonb, text, uuid) to authenticated, service_role;

-- -------------------------------------------------------------
-- 3) ① リマインド対象の判定（1 か所にまとめる）: 必須かつ未提出の全員を走査し、送る／送らない と理由を付ける
--    scope: new_hire（新規入社者）／batch（承認済みの対象リスト）／existing_unlisted（既存従業員・対象リスト未登録＝送らない）
-- -------------------------------------------------------------
create or replace function public.post_join_remind_scan_i(p_now timestamptz default now(), p_start_days integer default 3)
returns table(user_id uuid, workflow_id uuid, name text, role text, class text, store_names text, hire_date date, track text, target_year integer,
              deadline date, legal_deadline date, required_source text, last_reminded_at timestamptz, remind_count integer, interval_days integer,
              has_slack boolean, has_line boolean, channel text, scope text, batch_id uuid, batch_title text, included boolean, exclude_reason text, next_at timestamptz)
language plpgsql stable security definer set search_path to 'public'
as $$
declare u record; t text; e jsonb; v_today date; v_from date; v_order jsonb; v_b record; v_draft boolean; v_new boolean; v_year int;
begin
  v_today := (p_now at time zone 'Asia/Tokyo')::date;
  select coalesce(nullif(value ->> 'post_join_new_hire_from', '')::date, date '2026-11-09'), coalesce(value -> 'person_channel_order', '["slack","line"]'::jsonb)
    into v_from, v_order from app_settings where key = 'onboarding_alerts';
  v_from := coalesce(v_from, date '2026-11-09'); v_order := coalesce(v_order, '["slack","line"]'::jsonb);
  for u in select x.id, x.name, x.role, coalesce(p.hire_date, x.created_at::date) as hire_date, w.id as wf, w.status as wf_status, (w.created_at at time zone 'Asia/Tokyo')::date as wf_date,
                  (select string_agg(s.name, '・' order by s.sort_order) from user_stores us join stores s on s.id = us.store_id where us.user_id = x.id) as store_names,
                  exists(select 1 from user_slack us where us.user_id = x.id) as has_slack, (x.line_user_id is not null) as has_line
             from users x left join employee_profiles p on p.user_id = x.id left join onboarding_workflows w on w.user_id = x.id
            where x.is_active and x.role in ('AL','SHAIN','TENCHO','TEAM','HQ','CEO') order by x.created_at loop
    v_new := u.wf is not null and u.wf_status in ('registering','completed') and u.wf_date >= v_from;
    foreach t in array array['dependents','year_end'] loop
      e := public.post_join_effective_i(u.id, t, null);
      -- 必須・対象・フォーム利用可・未提出 だけが「リマインドの候補」
      if not ((e ->> 'required')::boolean and (e ->> 'target')::boolean and (e ->> 'form_enabled')::boolean and (e ->> 'status') = 'pending') then continue; end if;
      user_id := u.id; workflow_id := u.wf; name := u.name; role := u.role; class := e ->> 'class'; store_names := u.store_names; hire_date := u.hire_date;
      track := t; v_year := (e ->> 'target_year')::int; target_year := v_year; deadline := nullif(e ->> 'deadline', '')::date; legal_deadline := nullif(e ->> 'legal_deadline', '')::date;
      required_source := e ->> 'source_of_required'; last_reminded_at := nullif(e ->> 'last_reminded_at', '')::timestamptz; remind_count := (e ->> 'remind_count')::int;
      interval_days := case when deadline is not null and v_today > deadline then (e ->> 'remind_interval_after_deadline_days')::int else (e ->> 'remind_interval_days')::int end;
      has_slack := u.has_slack; has_line := u.has_line;
      channel := coalesce((select case o.v when 'slack' then 'Slack' else 'LINE' end from jsonb_array_elements_text(v_order) with ordinality o(v, n)
                            where (o.v = 'slack' and u.has_slack) or (o.v = 'line' and u.has_line) order by o.n limit 1), '送信先なし');
      batch_id := null; batch_title := null; v_draft := false; next_at := null;
      if v_new then
        scope := 'new_hire';
      else
        select b.id, b.title into v_b from post_join_remind_batches b join post_join_remind_members m on m.batch_id = b.id
         where m.user_id = u.id and m.removed_at is null and b.status = 'approved' and b.track in (t, 'both')
           and (t = 'dependents' or b.target_year is null or b.target_year = v_year)
         order by b.approved_at desc limit 1;
        if v_b.id is not null then scope := 'batch'; batch_id := v_b.id; batch_title := v_b.title;
        else
          scope := 'existing_unlisted';
          v_draft := exists(select 1 from post_join_remind_batches b join post_join_remind_members m on m.batch_id = b.id
                             where m.user_id = u.id and m.removed_at is null and b.status = 'draft' and b.track in (t, 'both'));
        end if;
      end if;
      included := true; exclude_reason := null;
      if scope = 'existing_unlisted' then included := false; exclude_reason := case when v_draft then '対象リストが未承認（下書き）' else '既存従業員（対象リスト未登録）' end;
      elsif not (e ->> 'remind_enabled')::boolean then included := false; exclude_reason := 'リマインド無効（設定）';
      elsif u.hire_date > v_today - p_start_days then included := false; exclude_reason := '入社 ' || p_start_days || ' 日未満'; next_at := (u.hire_date + p_start_days)::timestamp at time zone 'Asia/Tokyo';
      elsif last_reminded_at is not null and last_reminded_at + make_interval(days => interval_days) > p_now then
        included := false; next_at := last_reminded_at + make_interval(days => interval_days);
        exclude_reason := '間隔待ち（次回 ' || to_char(next_at at time zone 'Asia/Tokyo', 'MM/DD') || '）';
      end if;
      return next;
    end loop;
  end loop;
end $$;
revoke all on function public.post_join_remind_scan_i(timestamptz, integer) from public, anon, authenticated;
grant execute on function public.post_join_remind_scan_i(timestamptz, integer) to service_role;

-- 送信対象（EF が使う）。戻り列の末尾に scope / batch_id を追加したため drop → create（列名で読む既存の呼び出しは互換）
drop function if exists public.onboarding_post_join_targets(timestamptz, integer);
create function public.onboarding_post_join_targets(p_now timestamptz default now(), p_start_days integer default 3)
returns table(user_id uuid, workflow_id uuid, name text, hire_date date, track text, target_year integer, deadline date, required_source text, class text,
              last_reminded_at timestamptz, remind_count integer, interval_days integer, has_slack boolean, has_line boolean, scope text, batch_id uuid)
language plpgsql security definer set search_path to 'public' stable
as $$
begin
  if not (public.onboarding_is_service() or public.hq_can_manage()) then raise exception '権限がありません'; end if;
  return query select s.user_id, s.workflow_id, s.name, s.hire_date, s.track, s.target_year, s.deadline, s.required_source, s.class,
                      s.last_reminded_at, s.remind_count, s.interval_days, s.has_slack, s.has_line, s.scope, s.batch_id
                 from public.post_join_remind_scan_i(p_now, p_start_days) s where s.included;
end $$;
grant execute on function public.onboarding_post_join_targets(timestamptz, integer) to authenticated, service_role;

-- dry-run 画面の元データ（本部）: 必須かつ未提出の全員（送る人・送らない人と理由）。連絡先そのものは返さない
create or replace function public.onboarding_post_join_preview(p_now timestamptz default now())
returns table(user_id uuid, name text, class text, role text, store_names text, hire_date date, track text, target_year integer, deadline date, legal_deadline date,
              required_source text, scope text, batch_id uuid, batch_title text, included boolean, exclude_reason text, next_at timestamptz,
              remind_count integer, last_reminded_at timestamptz, has_slack boolean, has_line boolean, channel text)
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_days int;
begin
  if not (public.onboarding_is_service() or public.hq_can_manage()) then raise exception '権限がありません'; end if;
  select coalesce((value ->> 'post_join_remind_days')::int, 3) into v_days from app_settings where key = 'onboarding_alerts';
  return query select s.user_id, s.name, s.class, s.role, s.store_names, s.hire_date, s.track, s.target_year, s.deadline, s.legal_deadline,
                      s.required_source, s.scope, s.batch_id, s.batch_title, s.included, s.exclude_reason, s.next_at,
                      s.remind_count, s.last_reminded_at, s.has_slack, s.has_line, s.channel
                 from public.post_join_remind_scan_i(p_now, coalesce(v_days, 3)) s;
end $$;
grant execute on function public.onboarding_post_join_preview(timestamptz) to authenticated, service_role;

-- 一括通知の防止: 1 回の送信人数の上限（超えたら誰にも送らない）
create or replace function public.post_join_remind_guard(p_count integer)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('count', p_count, 'max_per_run', m.v, 'over_limit', coalesce(p_count, 0) > m.v)
    from (select coalesce((select (value ->> 'post_join_max_per_run')::int from app_settings where key = 'onboarding_alerts'), 10) as v) m;
$$;
grant execute on function public.post_join_remind_guard(integer) to authenticated, service_role;

-- 本人へ送る文面（EF と dry-run 画面が同じものを使う＝二重定義にしない）。p_tracks: [{track, target_year, deadline}]
create or replace function public.post_join_remind_text(p_name text, p_tracks jsonb)
returns text language plpgsql stable as $$
declare v_items text; v_deadline date; v_url constant text := 'https://mirai-oss.github.io/nippo/?page=settings#postjoin';
begin
  select string_agg(case x ->> 'track' when 'year_end' then '年末調整' || case when coalesce((x ->> 'target_year')::int, 0) > 0 then ' ' || (x ->> 'target_year') || ' 年度' else '' end else '扶養家族' end, '・' order by x ->> 'track' desc),
         min(nullif(x ->> 'deadline', '')::date)
    into v_items, v_deadline from jsonb_array_elements(coalesce(p_tracks, '[]'::jsonb)) x;
  return coalesce(p_name, '') || 'さん、お疲れさまです。N-Style 本部です。' || E'\n' ||
    coalesce(v_items, '年末調整と扶養家族') || 'の情報の登録をお願いします（扶養家族がいない場合も「いない」で送ってください）。' ||
    case when v_deadline is not null then '社内の期限は ' || to_char(v_deadline, 'FMMM/FMDD') || ' です。' else '' end || E'\n' ||
    '▶ ' || v_url || '（ログイン後の「設定」ページ）' || E'\n' ||
    'スマレジ・タイムカードの画面と同じ項目です。5 分ほどで終わります。分からない項目はそのまま送って、返信で教えてください。';
end $$;
grant execute on function public.post_join_remind_text(text, jsonb) to authenticated, service_role;

-- dry-run 画面用のまとめ（本部）: 有効かどうか・上限・今回送る人（文面つき）・送らない人の内訳。EF の dry_run も同じ内容を返す
create or replace function public.onboarding_post_join_preview_summary(p_now timestamptz default now())
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_set jsonb; v_will jsonb; v_exc jsonb; v_sum jsonb; v_n int; v_guard jsonb;
begin
  if not (public.onboarding_is_service() or public.hq_can_manage()) then raise exception '権限がありません'; end if;
  select value into v_set from app_settings where key = 'onboarding_alerts';
  select coalesce(jsonb_agg(w order by w ->> 'name'), '[]'::jsonb), count(*) into v_will, v_n from (
    select jsonb_build_object('user_id', p.user_id, 'name', min(p.name), 'class', min(p.class), 'role', min(p.role), 'store_names', min(p.store_names), 'hire_date', min(p.hire_date),
             'scope', min(p.scope), 'batch_title', min(p.batch_title), 'channel', min(p.channel),
             'tracks', jsonb_agg(jsonb_build_object('track', p.track, 'target_year', p.target_year, 'deadline', p.deadline, 'legal_deadline', p.legal_deadline, 'required_source', p.required_source, 'remind_count', p.remind_count) order by p.track),
             'text', public.post_join_remind_text(min(p.name), jsonb_agg(jsonb_build_object('track', p.track, 'target_year', p.target_year, 'deadline', p.deadline)))) as w
      from public.onboarding_post_join_preview(p_now) p where p.included group by p.user_id) x;
  select coalesce(jsonb_agg(jsonb_build_object('user_id', p.user_id, 'name', p.name, 'class', p.class, 'store_names', p.store_names, 'hire_date', p.hire_date, 'track', p.track, 'target_year', p.target_year,
             'deadline', p.deadline, 'scope', p.scope, 'exclude_reason', p.exclude_reason, 'next_at', p.next_at) order by p.name, p.track), '[]'::jsonb)
    into v_exc from public.onboarding_post_join_preview(p_now) p where not p.included;
  select coalesce(jsonb_object_agg(k, c), '{}'::jsonb) into v_sum from (
    select case when p.scope = 'existing_unlisted' then (case when p.exclude_reason like '%下書き%' then 'batch_draft' else 'existing_unlisted' end)
                when p.exclude_reason like 'リマインド無効%' then 'remind_disabled' when p.exclude_reason like '入社%' then 'before_start' else 'interval' end as k, count(distinct p.user_id) as c
      from public.onboarding_post_join_preview(p_now) p where not p.included group by 1) y;
  v_guard := public.post_join_remind_guard(v_n);
  return jsonb_build_object('ok', true, 'now', p_now,
    'enabled', coalesce((v_set ->> 'post_join_remind_enabled')::boolean, false), 'person_notify_enabled', coalesce((v_set ->> 'person_notify_enabled')::boolean, false),
    'new_hire_from', coalesce(v_set ->> 'post_join_new_hire_from', '2026-11-09'), 'start_days', coalesce((v_set ->> 'post_join_remind_days')::int, 3),
    'max_per_run', v_guard -> 'max_per_run', 'over_limit', v_guard -> 'over_limit', 'will_send_count', v_n, 'will_send', v_will,
    'excluded_count', jsonb_array_length(v_exc), 'excluded_summary', v_sum, 'excluded', v_exc,
    'note', case when (v_guard ->> 'over_limit')::boolean then '送信対象が上限を超えています。このままでは誰にも送られません（対象リストを分けるか、上限を見直してください）'
                 when not coalesce((v_set ->> 'post_join_remind_enabled')::boolean, false) then '自動送信は OFF です（これは確認用の表示で、何も送られません）' else null end);
end $$;
grant execute on function public.onboarding_post_join_preview_summary(timestamptz) to authenticated, service_role;

-- 必須なのに未提出の一覧ビュー（本部が案内する一覧）: 新版の実効ポリシーをそのまま使うため変更なし（post_join_required_pending_v）
