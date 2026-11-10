-- =============================================================
-- 切り戻し: 2026-11-10_post_join_remind_scope.sql（データ保全版・2026-11-10）
--   戻すもの: 実効ポリシー・標準ルール変更・送信対象の 3 関数を Phase 6 v2（2026-11-09 適用版）の定義に戻す／v3 で足した関数を削除／
--             標準ルールの社内期限を v2 の値（社員の扶養＝入社 14 日後と月末の早い方）に戻す／設定キー 2 つを外す
--   残すもの（データ保全）: 対象リストの表 post_join_remind_batches / post_join_remind_members と行、post_join_rules の法定期限の列（legal_deadline_basis / pay_day / pay_month_offset / legal_note。v2 の関数は使わない）、
--             post_join_policy_history の行と種類の制約（remind_* を含む行が残るため広いままにする）
--   注意: 切り戻すと「既存従業員も必須かつ未提出なら通知候補になる」v2 の動きに戻る。post_join_remind_enabled が false であることを必ず確認してから実行する
-- =============================================================
do $$ begin
  if coalesce((select (value ->> 'post_join_remind_enabled')::boolean from app_settings where key = 'onboarding_alerts'), false) then
    raise exception '切り戻しの前に onboarding_alerts.post_join_remind_enabled を false にしてください（v2 の対象判定は既存従業員も候補にします）';
  end if;
end $$;

-- v3 で足した関数を削除
drop function if exists public.onboarding_post_join_preview_summary(timestamptz);
drop function if exists public.onboarding_post_join_preview(timestamptz);
drop function if exists public.post_join_remind_text(text, jsonb);
drop function if exists public.post_join_remind_guard(integer);
drop function if exists public.post_join_remind_settings_set(jsonb, text, uuid);
drop function if exists public.post_join_remind_batch_members(uuid);
drop function if exists public.post_join_remind_batch_list();
drop function if exists public.post_join_remind_member_remove(uuid, uuid, uuid);
drop function if exists public.post_join_remind_batch_cancel(uuid, uuid, text);
drop function if exists public.post_join_remind_batch_approve(uuid, uuid);
drop function if exists public.post_join_remind_batch_create(text, text, integer, uuid[], jsonb, text, uuid);

-- 送信対象: v2 の定義に戻す（戻り列が違うため drop → create）
drop function if exists public.onboarding_post_join_targets(timestamptz, integer);
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
drop function if exists public.post_join_remind_scan_i(timestamptz, integer);

-- 実効ポリシー: v2 の定義に戻す
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
drop function if exists public.post_join_legal_deadline(text, date, integer, integer, integer, integer);

-- 標準ルールの変更: v2 の定義に戻す
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

-- 標準ルールの社内期限を v2 の値に戻す（法定期限の列は残す）
update public.post_join_rules set deadline_days = 14,
       note = '社員: 扶養フォームは社内運用上 提出必須。期限＝入社 14 日後 と 初回給与処理に必要な期限（入社後最初の締め日 − リード日数）の早い方', updated_at = now()
 where class = 'SHAIN' and track = 'dependents' and deadline_days is null;
update public.post_join_rules set payroll_closing_day = null,
       note = 'アルバイト: 利用可・初期は任意・リマインドなし（本部が個別に必須へ変更可）', updated_at = now()
 where class = 'AL' and track = 'dependents';

-- 設定キーを外す
update app_settings set value = value - 'post_join_new_hire_from' - 'post_join_max_per_run' where key = 'onboarding_alerts';
