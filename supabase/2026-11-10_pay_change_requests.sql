-- 賃金変更・銀行口座変更の承認と履歴（ステップ 3・2026-11-10）
--   設計: docs/設計書_従業員情報変更の連動_2026-11-10.md §9・§10
--   ★ 本番未適用（開発・テストのみ承認。適用は別途承認）。戻し方: 2026-11-10_pay_change_requests_rollback.sql
--   前提: 2026-11-10_employee_change_events.sql（適用済み）＝直接編集も含めて変更前後・変更者は必ず履歴に残る
--
--   再利用するもの（新しい申請の仕組みは作らない）:
--     ・申請の表 profile_change_requests（本人の口座変更申請 submit_profile_change_request／承認 review_profile_change_request はそのまま使える）
--     ・賃金の登録 hr_save_wage（適用開始日つき・スマレジ同期と読み戻しは既存の wage_push／wage_pull と employee_wage_settings.sync_status）
--     ・振込データの出力の印 payroll_transfer_schedule（出力時に行が出来る）・給与確定 payroll_finalized
--   足すもの:
--     ・申請に「適用開始日（賃金）」「何月分の給与＝何月何日支給分から（口座）」「理由」「反映の状態」
--     ・承認は申請者と別の人（マスターは自分の申請も承認可）。承認まで賃金・口座は変わらない＝スマレジ同期も承認後だけ
--     ・締め済みは自動で上書きしない: 賃金＝適用開始月が給与確定済みなら承認を止める（マスターが理由つきで明示したときだけ通す）
--                                     口座＝その支給回の振込データが出力済み・支給日を過ぎていれば反映しない（本部が支給回を選び直す）
--     ・口座は「前の支給回の振込データが出力されるまで」現在の口座を書き換えない（予約）。出力の直後に自動で切り替わる（承認済みの予約の実行）
--     ・振込データを出力した時点の口座の控え payroll_transfer_account_snapshots
--     ・直接編集の禁止（承認必須化）は app_settings.employee_change.pay_approval_required（既定 false＝これまでどおり直接編集も可・履歴は残る）

-- ============ 1. 申請の表を拡張 ============
alter table profile_change_requests add column if not exists payload jsonb;
alter table profile_change_requests add column if not exists effective_date date;            -- 賃金: 適用開始日
alter table profile_change_requests add column if not exists effective_year_month text;      -- 口座: この月分の給与から（例 2026-11 ＝ 12/15 支給分）
alter table profile_change_requests add column if not exists effective_pay_date date;        -- 口座: その支給日（表示用。予定日が決まっていればその日、無ければ翌月 15 日）
alter table profile_change_requests add column if not exists request_reason text;
alter table profile_change_requests add column if not exists apply_status text not null default 'none';
alter table profile_change_requests add column if not exists applied_at timestamptz;
alter table profile_change_requests add column if not exists apply_note text;
alter table profile_change_requests add column if not exists apply_ref jsonb;
alter table profile_change_requests drop constraint if exists profile_change_requests_field_check;
alter table profile_change_requests add constraint profile_change_requests_field_check check (field = any (array['name','kana','phone','address','bank_account','contact_email','id_document','wage']));
alter table profile_change_requests drop constraint if exists profile_change_requests_status_check;
alter table profile_change_requests add constraint profile_change_requests_status_check check (status = any (array['pending','approved','rejected','cancelled']));
alter table profile_change_requests drop constraint if exists profile_change_requests_apply_status_check;
alter table profile_change_requests add constraint profile_change_requests_apply_status_check check (apply_status = any (array['none','applied','scheduled','blocked_exported','blocked_finalized']));
create unique index if not exists profile_change_requests_bank_pending on profile_change_requests(user_id) where field = 'bank_account' and status = 'pending';
create unique index if not exists profile_change_requests_bank_scheduled on profile_change_requests(user_id) where field = 'bank_account' and status = 'approved' and apply_status in ('scheduled','blocked_exported');

-- 振込データを出力した時点の口座の控え（どの口座に振り込んだかを支給回ごとに残す）
create table if not exists payroll_transfer_account_snapshots (
  year_month text not null, user_id uuid not null references users(id) on delete cascade,
  account jsonb not null, taken_at timestamptz not null default now(), taken_by uuid,
  primary key (year_month, user_id)
);
alter table payroll_transfer_account_snapshots enable row level security;
drop policy if exists payroll_transfer_account_snapshots_read on payroll_transfer_account_snapshots;
create policy payroll_transfer_account_snapshots_read on payroll_transfer_account_snapshots for select using (is_profile_approver());

update app_settings set value = value || '{"pay_approval_required": false}'::jsonb where key = 'employee_change' and not (value ? 'pay_approval_required');

-- ============ 2. 支給回の補助（給与は末日締め・翌月 15 日払い） ============
create or replace function pay_run_date(p_year_month text) returns date language sql stable security definer set search_path = public as $$
  select coalesce((select scheduled_date from payroll_transfer_schedule where year_month = p_year_month), (to_date(p_year_month || '-01', 'YYYY-MM-DD') + interval '1 month' + interval '14 days')::date)
$$;
-- その支給回は「もう変えられない」か（振込データを出力済み、または支給日を過ぎた）
create or replace function pay_run_closed(p_year_month text, p_today date default current_date) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from payroll_transfer_schedule where year_month = p_year_month) or p_today > pay_run_date(p_year_month)
$$;
-- 次に変えられる支給回（まだ出力していない最も早い月）
create or replace function pay_run_next_open(p_today date default current_date) returns text language sql stable security definer set search_path = public as $$
  select to_char(m, 'YYYY-MM') from generate_series(date_trunc('month', p_today) - interval '2 month', date_trunc('month', p_today) + interval '2 month', interval '1 month') m
   where not pay_run_closed(to_char(m, 'YYYY-MM'), p_today) order by m limit 1
$$;
create or replace function employee_change_group_of_request(p_field text)
returns text language sql immutable as $$
  select case p_field when 'name' then 'name' when 'kana' then 'name' when 'phone' then 'contact' when 'contact_email' then 'contact' when 'address' then 'address' when 'bank_account' then 'bank_account' when 'wage' then 'wage' else null end
$$;

-- ============ 3. 申請 ============
-- 賃金（本部・社長・マスター）と銀行口座（本人または本部）。この時点では賃金・口座は変わらない
create or replace function hr_pay_change_request(p_user uuid, p_kind text, p_payload jsonb, p_effective_date date default null, p_year_month text default null, p_reason text default null, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; v_old jsonb; v_id uuid; v_warn text[] := '{}'; v_corp uuid; v_ym text;
begin
  if p_kind not in ('wage', 'bank_account') then raise exception '種類が不正です'; end if;
  if p_kind = 'bank_account' and auth.uid() is not null and auth.uid() = p_user then v_actor := auth.uid();     -- 本人の口座変更申請
  else v_actor := public.onboarding_resolve_actor(p_actor); end if;                                           -- それ以外は本部・社長・マスター
  if not exists (select 1 from users where id = p_user) then raise exception '対象の従業員が見つかりません'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null and v_actor <> p_user then raise exception '変更の理由を入れてください'; end if;
  if p_kind = 'wage' then
    if p_effective_date is null then raise exception '適用開始日を指定してください'; end if;
    if coalesce((p_payload ->> 'wage')::int, 0) <= 0 or (p_payload ->> 'contract_id') is null or (p_payload ->> 'division') is null then raise exception '賃金の内容（契約・給与形態・金額）が足りません'; end if;
    if exists (select 1 from profile_change_requests where user_id = p_user and field = 'wage' and status = 'pending' and effective_date = p_effective_date
               and payload ->> 'contract_id' = p_payload ->> 'contract_id' and payload ->> 'division' = p_payload ->> 'division' and coalesce(payload ->> 'store_id', '') = coalesce(p_payload ->> 'store_id', '')) then
      raise exception '同じ適用開始日の賃金変更がすでに承認待ちです';
    end if;
    select jsonb_build_object('wage', w.wage, 'holiday_wage', w.holiday_wage, 'effective_date', w.effective_date) into v_old from employee_wage_settings w
     where w.user_id = p_user and w.contract_id = p_payload ->> 'contract_id' and w.division = (p_payload ->> 'division')::int and coalesce(w.store_id::text, '') = coalesce(p_payload ->> 'store_id', '') and w.effective_date <= p_effective_date
     order by w.effective_date desc limit 1;
    select s.corporation_id into v_corp from user_stores us join stores s on s.id = us.store_id where us.user_id = p_user order by us.is_primary desc, s.sort_order limit 1;
    v_ym := to_char(p_effective_date, 'YYYY-MM');
    if exists (select 1 from payroll_finalized f where f.year_month = v_ym and (v_corp is null or f.corporation_id = v_corp)) then v_warn := v_warn || text '適用開始月の給与は確定済みです（承認時に止まります。マスターが理由つきで明示したときだけ反映）'; end if;
    if p_effective_date < date_trunc('month', current_date)::date then v_warn := v_warn || text '適用開始日が過去の月です（さかのぼり分は自動では精算しません）'; end if;
    insert into profile_change_requests(user_id, field, old_value, new_value, payload, effective_date, request_reason, requested_by)
    values (p_user, 'wage', v_old::text, p_payload::text, p_payload, p_effective_date, nullif(trim(coalesce(p_reason, '')), ''), v_actor) returning id into v_id;
  else
    if coalesce(p_payload ->> 'payment_method', 'bank_transfer') = 'bank_transfer' and (nullif(p_payload ->> 'bank_code', '') is null or nullif(p_payload ->> 'branch_code', '') is null or nullif(p_payload ->> 'account_number', '') is null or nullif(p_payload ->> 'account_holder_kana', '') is null) then
      raise exception '口座の内容（銀行コード・支店コード・口座番号・名義カナ）が足りません';
    end if;
    if exists (select 1 from profile_change_requests where user_id = p_user and field = 'bank_account' and status = 'pending') then raise exception '口座変更の申請がすでに承認待ちです'; end if;
    v_ym := coalesce(nullif(trim(coalesce(p_year_month, '')), ''), pay_run_next_open());
    if v_ym !~ '^\d{4}-\d{2}$' then raise exception '適用する月（YYYY-MM）が不正です'; end if;
    if pay_run_closed(v_ym) then raise exception '% 月分の給与（% 支給）は振込データを出力済みか支給日を過ぎています。次の支給回を選んでください', v_ym, pay_run_date(v_ym); end if;
    select to_jsonb(b) - 'created_at' - 'updated_at' - 'updated_by' - 'user_id' into v_old from payroll_bank_accounts b where b.user_id = p_user;
    insert into profile_change_requests(user_id, field, old_value, new_value, payload, effective_year_month, effective_pay_date, request_reason, requested_by)
    values (p_user, 'bank_account', v_old::text, p_payload::text, p_payload, v_ym, pay_run_date(v_ym), nullif(trim(coalesce(p_reason, '')), ''), v_actor) returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'request_id', v_id, 'warnings', to_jsonb(v_warn), 'effective_year_month', v_ym, 'effective_pay_date', case when p_kind = 'bank_account' then pay_run_date(v_ym) end);
end $$;

-- ============ 4. 口座の反映（承認済みの申請だけ。締め済みは書かない・前の支給回が済むまで予約） ============
create or replace function hr_bank_change_try_apply(p_request uuid, p_actor uuid default null)
returns text language plpgsql security definer set search_path = public as $$
declare q profile_change_requests%rowtype; b jsonb; v_prev text; v_status text;
begin
  select * into q from profile_change_requests where id = p_request for update;
  if q.id is null or q.field <> 'bank_account' or q.status <> 'approved' or q.apply_status = 'applied' then return q.apply_status; end if;
  b := coalesce(q.payload, q.new_value::jsonb);
  if q.effective_year_month is null then
    update profile_change_requests set effective_year_month = pay_run_next_open(), effective_pay_date = pay_run_date(pay_run_next_open()) where id = q.id returning * into q;
  end if;
  v_prev := to_char(to_date(q.effective_year_month || '-01', 'YYYY-MM-DD') - interval '1 month', 'YYYY-MM');
  if pay_run_closed(q.effective_year_month) then
    v_status := 'blocked_exported';   -- その支給回は出力済み／支給日を過ぎた → 自動では書かない
    update profile_change_requests set apply_status = v_status, apply_note = q.effective_year_month || ' 月分（' || pay_run_date(q.effective_year_month) || ' 支給）は振込データを出力済みか支給日を過ぎています。支給回を選び直してください' where id = q.id;
  elsif not pay_run_closed(v_prev) then
    v_status := 'scheduled';          -- 前の支給回がまだ → 今の口座は書き換えない（前の回の振込データを出力した直後に切り替わる）
    update profile_change_requests set apply_status = v_status, apply_note = v_prev || ' 月分の振込データを出力したあとに切り替わります（' || pay_run_date(q.effective_year_month) || ' 支給分から新しい口座）' where id = q.id;
  else
    perform set_config('employee_change.via_approval', q.id::text, true);
    insert into payroll_bank_accounts(user_id, bank_code, bank_name, branch_code, branch_name, account_type, account_number, account_holder_kana, payment_method, updated_by, updated_at)
    values (q.user_id, b ->> 'bank_code', b ->> 'bank_name', b ->> 'branch_code', b ->> 'branch_name', coalesce(b ->> 'account_type', '1'), b ->> 'account_number', b ->> 'account_holder_kana', coalesce(b ->> 'payment_method', 'bank_transfer'), coalesce(q.reviewed_by, p_actor), now())
    on conflict (user_id) do update set bank_code = excluded.bank_code, bank_name = excluded.bank_name, branch_code = excluded.branch_code, branch_name = excluded.branch_name, account_type = excluded.account_type,
      account_number = excluded.account_number, account_holder_kana = excluded.account_holder_kana, payment_method = excluded.payment_method, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
    perform set_config('employee_change.via_approval', '', true);
    v_status := 'applied';
    update profile_change_requests set apply_status = v_status, applied_at = now(), apply_note = pay_run_date(q.effective_year_month) || ' 支給分から新しい口座' where id = q.id;
    -- 履歴（ステップ 1 の記録）に申請者・承認者をひも付ける
    update employee_change_events set source = 'request', request_table = 'profile_change_requests', request_id = q.id, requested_by = q.requested_by, requested_at = q.requested_at,
           approved_by = q.reviewed_by, approved_at = q.reviewed_at, effective_date = q.effective_pay_date
     where user_id = q.user_id and field_group = 'bank_account' and txid = txid_current();
  end if;
  return v_status;
end $$;

-- ============ 5. 承認・却下 ============
create or replace function hr_pay_change_review(p_request uuid, p_approve boolean, p_reason text default null, p_actor uuid default null, p_force_closed boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; q profile_change_requests%rowtype; v_master boolean; v_corp uuid; v_ym text; r jsonb; v_apply text;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select coalesce(is_master, false) into v_master from users where id = v_actor;
  select * into q from profile_change_requests where id = p_request and status = 'pending' for update;
  if q.id is null then raise exception '対象の申請が見つからないか、既に処理済みです'; end if;
  if q.field not in ('wage', 'bank_account') then raise exception 'この申請は対象外です'; end if;
  if not p_approve then
    if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception '却下の理由を入れてください'; end if;
    update profile_change_requests set status = 'rejected', reviewed_by = v_actor, reviewed_at = now(), reject_reason = trim(p_reason) where id = q.id;
    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;
  -- 2 人目の確認: 申請した本人は承認できない（マスターだけは自分の申請も承認できる＝申請と承認の両方が記録に残る）
  if q.requested_by = v_actor and not v_master then raise exception '申請した人とは別の人が承認してください'; end if;
  if q.field = 'bank_account' and q.user_id = v_actor and not v_master then raise exception '自分の口座の変更は自分では承認できません'; end if;
  if q.field = 'wage' then
    v_ym := to_char(q.effective_date, 'YYYY-MM');
    select s.corporation_id into v_corp from user_stores us join stores s on s.id = us.store_id where us.user_id = q.user_id order by us.is_primary desc, s.sort_order limit 1;
    if exists (select 1 from payroll_finalized f where f.year_month = v_ym and (v_corp is null or f.corporation_id = v_corp)) then
      if not (coalesce(p_force_closed, false) and v_master and nullif(trim(coalesce(p_reason, '')), '') is not null) then
        update profile_change_requests set apply_status = 'blocked_finalized', apply_note = v_ym || ' の給与は確定済みのため自動では反映しません（適用開始日を変えて申請し直すか、マスターが理由つきで明示して承認）' where id = q.id;
        return jsonb_build_object('ok', false, 'blocked', 'finalized', 'error', v_ym || ' の給与は確定済みです。自動では上書きしません');
      end if;
    end if;
    update profile_change_requests set status = 'approved', reviewed_by = v_actor, reviewed_at = now(), reject_reason = null,
           apply_note = case when coalesce(p_force_closed, false) then '確定済みの月への反映をマスターが承認: ' || trim(p_reason) else null end where id = q.id;
    perform set_config('employee_change.via_approval', q.id::text, true);
    r := hr_save_wage(q.user_id, q.payload ->> 'contract_id', (q.payload ->> 'division')::int, nullif(q.payload ->> 'store_id', '')::uuid, (q.payload ->> 'wage')::int, nullif(q.payload ->> 'holiday_wage', '')::int, q.effective_date, v_actor);
    perform set_config('employee_change.via_approval', '', true);
    update profile_change_requests set apply_status = 'applied', applied_at = now(), apply_ref = jsonb_build_object('wage_setting_id', r ->> 'id') where id = q.id;
    update employee_change_events set source = 'request', request_table = 'profile_change_requests', request_id = q.id, requested_by = q.requested_by, requested_at = q.requested_at, approved_by = v_actor, approved_at = now()
     where user_id = q.user_id and field_group = 'wage' and txid = txid_current();
    -- スマレジへの同期はここでは行わない（登録された行は sync_status=pending。既存の賃金同期＝wage_push → 読み戻し wage_pull が拾う）
    return jsonb_build_object('ok', true, 'status', 'approved', 'apply_status', 'applied', 'wage_setting_id', r ->> 'id', 'sync', 'pending');
  end if;
  update profile_change_requests set status = 'approved', reviewed_by = v_actor, reviewed_at = now(), reject_reason = null where id = q.id;
  v_apply := hr_bank_change_try_apply(q.id, v_actor);
  return jsonb_build_object('ok', true, 'status', 'approved', 'apply_status', v_apply, 'note', (select apply_note from profile_change_requests where id = q.id));
end $$;

-- 予約中の口座変更のうち、前の支給回が済んだものを反映（振込データの出力直後に自動で呼ばれる。本部が手で呼ぶこともできる）
create or replace function hr_apply_due_bank_changes_internal() returns integer language plpgsql security definer set search_path = public as $$
declare x record; n integer := 0;
begin
  for x in select id from profile_change_requests where field = 'bank_account' and status = 'approved' and apply_status = 'scheduled' order by reviewed_at loop
    if hr_bank_change_try_apply(x.id, null) = 'applied' then n := n + 1; end if;
  end loop;
  return n;
end $$;
create or replace function hr_apply_due_bank_changes(p_actor uuid default null) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform public.onboarding_resolve_actor(p_actor);
  return jsonb_build_object('ok', true, 'applied', hr_apply_due_bank_changes_internal());
end $$;
-- 出力済みで止まった口座変更の支給回を選び直す
create or replace function hr_bank_change_reschedule(p_request uuid, p_year_month text, p_actor uuid default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_actor uuid; q profile_change_requests%rowtype;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into q from profile_change_requests where id = p_request and field = 'bank_account' and status = 'approved' and apply_status in ('blocked_exported', 'scheduled') for update;
  if q.id is null then raise exception '対象が見つかりません'; end if;
  if p_year_month !~ '^\d{4}-\d{2}$' or pay_run_closed(p_year_month) then raise exception 'その支給回は選べません（出力済みか支給日を過ぎています）'; end if;
  update profile_change_requests set effective_year_month = p_year_month, effective_pay_date = pay_run_date(p_year_month), apply_status = 'none' where id = q.id;
  return jsonb_build_object('ok', true, 'apply_status', hr_bank_change_try_apply(q.id, v_actor));
end $$;
-- 取り下げ（承認待ちのあいだだけ。申請者本人か本部）
create or replace function hr_pay_change_cancel(p_request uuid, p_actor uuid default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare q profile_change_requests%rowtype; v_actor uuid;
begin
  select * into q from profile_change_requests where id = p_request and field in ('wage', 'bank_account') and status = 'pending' for update;
  if q.id is null then raise exception '対象の申請が見つからないか、既に処理済みです'; end if;
  if auth.uid() is not null and auth.uid() = q.requested_by then v_actor := auth.uid(); else v_actor := public.onboarding_resolve_actor(p_actor); end if;
  update profile_change_requests set status = 'cancelled', reviewed_by = v_actor, reviewed_at = now() where id = q.id;
  return jsonb_build_object('ok', true);
end $$;

-- ============ 6. 振込データの出力（既存: payroll_transfer_schedule に行が出来る）に合わせて、口座の控えと予約の実行 ============
create or replace function payroll_transfer_schedule_after() returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    insert into payroll_transfer_account_snapshots(year_month, user_id, account, taken_by)
    select new.year_month, b.user_id, to_jsonb(b) - 'created_at' - 'updated_at' - 'updated_by' - 'user_id', auth.uid() from payroll_bank_accounts b
    on conflict (year_month, user_id) do update set account = excluded.account, taken_at = now(), taken_by = excluded.taken_by;
    perform hr_apply_due_bank_changes_internal();   -- この回の出力が済んだので、次の回からの予約を反映
  exception when others then perform employee_change_log_error('payroll_transfer_schedule', lower(tg_op), null, sqlerrm);
  end;
  return null;
end $$;
drop trigger if exists payroll_transfer_schedule_after on payroll_transfer_schedule;
create trigger payroll_transfer_schedule_after after insert or update on payroll_transfer_schedule for each row execute function payroll_transfer_schedule_after();

-- ============ 7. 直接編集の禁止（承認必須化）。既定 OFF＝これまでどおり（履歴は残る） ============
create or replace function employee_change_pay_guard() returns trigger language plpgsql security definer set search_path = public as $$
declare v_on boolean; v_user uuid; v_initial boolean;
begin
  select coalesce((value ->> 'pay_approval_required')::boolean, false) into v_on from app_settings where key = 'employee_change';
  if not coalesce(v_on, false) then return coalesce(new, old); end if;
  if coalesce(current_setting('employee_change.via_approval', true), '') <> '' then return coalesce(new, old); end if;   -- 承認の処理からの書き込み
  if auth.uid() is null then return coalesce(new, old); end if;                                                          -- システム処理（スマレジ同期・Slack の入社時の賃金設定）
  if tg_op = 'DELETE' then v_user := old.user_id; else v_user := new.user_id; end if;
  if tg_table_name = 'employee_wage_settings' then
    if tg_op = 'UPDATE' and (new.wage, new.holiday_wage, new.effective_date, new.division, new.store_id, new.contract_id) is not distinct from (old.wage, old.holiday_wage, old.effective_date, old.division, old.store_id, old.contract_id) then return new; end if;   -- 同期状態だけの更新
    v_initial := tg_op = 'INSERT' and not exists (select 1 from employee_wage_settings w where w.user_id = v_user);
  else
    v_initial := tg_op = 'INSERT';
  end if;
  if v_initial then return new; end if;   -- 初回の登録（入社時）は従来どおり
  raise exception '賃金・銀行口座の変更は「申請 → 承認」が必要です（従業員ページの変更申請から）';
end $$;
drop trigger if exists employee_change_pay_guard on employee_wage_settings;
create trigger employee_change_pay_guard before insert or update or delete on employee_wage_settings for each row execute function employee_change_pay_guard();
drop trigger if exists employee_change_pay_guard on payroll_bank_accounts;
create trigger employee_change_pay_guard before insert or update or delete on payroll_bank_accounts for each row execute function employee_change_pay_guard();

-- ============ 8. 一覧（本部系）。口座番号は マスター・本部以外には下 3 桁だけ ============
create or replace function hr_pay_change_list(p_user uuid default null, p_only_open boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_full boolean := is_profile_approver() or onboarding_is_service();
begin
  if not (hq_can_manage() or onboarding_is_service() or (p_user is not null and auth.uid() = p_user)) then raise exception '権限がありません'; end if;
  if not (hq_can_manage() or onboarding_is_service()) then v_full := false; end if;
  return coalesce((select jsonb_agg(x order by x.requested_at desc) from (
    select q.id, q.user_id, (select name from users u where u.id = q.user_id) user_name, q.field, q.status, q.apply_status, q.apply_note, q.applied_at, q.request_reason, q.reject_reason,
           q.effective_date, q.effective_year_month, q.effective_pay_date, (select name from users u where u.id = q.requested_by) requested_by_name, q.requested_at,
           (select name from users u where u.id = q.reviewed_by) reviewed_by_name, q.reviewed_at,
           case when q.field = 'wage' then case when hq_can_manage() or onboarding_is_service() then coalesce(q.payload, q.new_value::jsonb) end
                else (case when v_full then coalesce(q.payload, q.new_value::jsonb) else coalesce(q.payload, q.new_value::jsonb) - 'account_number' || jsonb_build_object('account_number', '****' || right(coalesce(coalesce(q.payload, q.new_value::jsonb) ->> 'account_number', ''), 3)) end) end new_value,
           case when q.field = 'wage' then case when hq_can_manage() or onboarding_is_service() then q.old_value::jsonb end
                when q.old_value is null then null
                else (case when v_full then q.old_value::jsonb else q.old_value::jsonb - 'account_number' || jsonb_build_object('account_number', '****' || right(coalesce(q.old_value::jsonb ->> 'account_number', ''), 3)) end) end old_value,
           (select jsonb_build_object('sync_status', w.sync_status, 'synced_at', w.synced_at, 'sync_error', w.sync_error, 'smaregi_wage_apply_id', w.smaregi_wage_apply_id) from employee_wage_settings w where w.id = nullif(q.apply_ref ->> 'wage_setting_id', '')::uuid) sync,
           (q.requested_by = auth.uid()) mine
      from profile_change_requests q
     where q.field in ('wage', 'bank_account') and (p_user is null or q.user_id = p_user)
       and (not coalesce(p_only_open, false) or q.status = 'pending' or (q.status = 'approved' and q.apply_status in ('scheduled', 'blocked_exported', 'blocked_finalized')))
     order by q.requested_at desc limit 200) x), '[]'::jsonb);
end $$;

-- ============ 9. 既存の承認関数（ポータルの申請画面が使う）から共通の承認へ回す ============
CREATE OR REPLACE FUNCTION public.review_profile_change_request(p_request_id uuid, p_approve boolean, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_req profile_change_requests%rowtype;
  v_bank jsonb;
begin
  if not is_profile_approver() then
    raise exception '権限がありません';
  end if;

  select * into v_req from profile_change_requests
    where id = p_request_id and status = 'pending' for update;
  if not found then
    raise exception '対象の申請が見つからないか、既に処理済みです';
  end if;

  -- 2026-11-10 ステップ 3: 銀行口座・賃金は「適用する支給回／適用開始日・締め済みの確認・2 人目の承認」を通す共通の承認へ回す
  if v_req.field in ('bank_account', 'wage') then
    perform hr_pay_change_review(p_request_id, p_approve, p_reason, null, false);
    return;
  end if;

  if p_approve then
    if v_req.field = 'name' then
      update users set name = v_req.new_value where id = v_req.user_id;
    elsif v_req.field = 'kana' then
      insert into employee_profiles (user_id, name_kana) values (v_req.user_id, v_req.new_value)
        on conflict (user_id) do update set name_kana = excluded.name_kana, updated_at = now();
    elsif v_req.field = 'phone' then
      insert into employee_profiles (user_id, phone) values (v_req.user_id, v_req.new_value)
        on conflict (user_id) do update set phone = excluded.phone, updated_at = now();
    elsif v_req.field = 'address' then
      insert into employee_profiles (user_id, address) values (v_req.user_id, v_req.new_value)
        on conflict (user_id) do update set address = excluded.address, updated_at = now();
    elsif v_req.field = 'contact_email' then
      insert into employee_profiles (user_id, extra) values (v_req.user_id, jsonb_build_object('contact_email', v_req.new_value))
        on conflict (user_id) do update set
          extra = coalesce(employee_profiles.extra, '{}'::jsonb) || jsonb_build_object('contact_email', v_req.new_value),
          updated_at = now();
    elsif v_req.field = 'id_document' then
      null; -- 反映先の列は無い。承認された記録がこの行自体に残ればよい
    elsif v_req.field = 'bank_account' then
      v_bank := v_req.new_value::jsonb;
      insert into payroll_bank_accounts
        (user_id, bank_code, bank_name, branch_code, branch_name,
         account_type, account_number, account_holder_kana, updated_by, updated_at)
      values (
        v_req.user_id,
        v_bank->>'bank_code', v_bank->>'bank_name',
        v_bank->>'branch_code', v_bank->>'branch_name',
        coalesce(v_bank->>'account_type','1'),
        v_bank->>'account_number', v_bank->>'account_holder_kana',
        auth.uid(), now()
      )
      on conflict (user_id) do update set
        bank_code = excluded.bank_code, bank_name = excluded.bank_name,
        branch_code = excluded.branch_code, branch_name = excluded.branch_name,
        account_type = excluded.account_type, account_number = excluded.account_number,
        account_holder_kana = excluded.account_holder_kana,
        updated_by = excluded.updated_by, updated_at = excluded.updated_at;
    end if;

    update profile_change_requests
      set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now()
      where id = p_request_id;
  else
    update profile_change_requests
      set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), reject_reason = p_reason
      where id = p_request_id;
  end if;
end $function$;

revoke all on function hr_bank_change_try_apply(uuid, uuid) from public, anon, authenticated;
revoke all on function hr_apply_due_bank_changes_internal() from public, anon, authenticated;
revoke all on function payroll_transfer_schedule_after() from public, anon, authenticated;
revoke all on function employee_change_pay_guard() from public, anon, authenticated;
revoke all on function hr_pay_change_request(uuid, text, jsonb, date, text, text, uuid) from public, anon;
revoke all on function hr_pay_change_review(uuid, boolean, text, uuid, boolean) from public, anon;
revoke all on function hr_apply_due_bank_changes(uuid) from public, anon;
revoke all on function hr_bank_change_reschedule(uuid, text, uuid) from public, anon;
revoke all on function hr_pay_change_cancel(uuid, uuid) from public, anon;
revoke all on function hr_pay_change_list(uuid, boolean) from public, anon;
grant execute on function hr_pay_change_request(uuid, text, jsonb, date, text, text, uuid) to authenticated, service_role;
grant execute on function hr_pay_change_review(uuid, boolean, text, uuid, boolean) to authenticated, service_role;
grant execute on function hr_apply_due_bank_changes(uuid) to authenticated, service_role;
grant execute on function hr_bank_change_reschedule(uuid, text, uuid) to authenticated, service_role;
grant execute on function hr_pay_change_cancel(uuid, uuid) to authenticated, service_role;
grant execute on function hr_pay_change_list(uuid, boolean) to authenticated, service_role;
