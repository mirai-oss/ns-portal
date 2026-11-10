-- 戻し: 賃金変更・銀行口座変更の承認（2026-11-10_pay_change_requests.sql）を取り消す。承認待ち・予約中の申請がある場合は先に処理すること（列ごと消える）
drop trigger if exists employee_change_pay_guard on employee_wage_settings;
drop trigger if exists employee_change_pay_guard on payroll_bank_accounts;
drop trigger if exists payroll_transfer_schedule_after on payroll_transfer_schedule;
drop trigger if exists pay_change_request_after on profile_change_requests;
drop trigger if exists payroll_transfer_schedule_guard on payroll_transfer_schedule;
drop trigger if exists payroll_transfer_confirm_step_guard on hq_task_steps;
drop function if exists payroll_transfer_confirm_step_guard();
-- review_profile_change_request を変更前の定義に戻す
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
drop function if exists hr_payroll_transfer_prepare(text);
drop function if exists hr_pay_change_config(uuid);
drop function if exists hr_pay_change_attention(text);
drop function if exists hr_pay_change_attention_internal(text);
drop function if exists pay_change_trg_request();
drop function if exists pay_change_task_close(uuid);
drop function if exists pay_change_task_open(uuid);
drop function if exists pay_change_notify(uuid, text);
drop function if exists pay_change_notify_op(text, jsonb);
drop function if exists pay_transfer_hold_task_sync(text);
drop function if exists payroll_transfer_schedule_guard();
drop function if exists employee_change_pay_direct_allowed(text, uuid, text);
drop function if exists hr_pay_change_list(uuid, boolean);
drop function if exists hr_pay_change_cancel(uuid, uuid);
drop function if exists hr_bank_change_reschedule(uuid, text, uuid, boolean, text);
drop function if exists hr_apply_due_bank_changes(uuid);
drop function if exists hr_apply_due_bank_changes_internal();
drop function if exists hr_pay_change_review(uuid, boolean, text, uuid, boolean, text);
drop function if exists hr_bank_change_try_apply(uuid, uuid);
drop function if exists hr_bank_change_apply_exception(uuid, text, uuid, text);
drop function if exists hr_bank_change_write(uuid, uuid);
drop function if exists hr_pay_change_request(uuid, text, jsonb, date, text, text, uuid);
drop function if exists employee_change_pay_guard();
drop function if exists payroll_transfer_schedule_after();
drop function if exists pay_run_next_open(date);
drop function if exists pay_transfer_pending_holds(text);
drop function if exists pay_run_user_state(text, uuid, date);
drop function if exists pay_run_closed(text, date);
drop function if exists pay_run_state(text, date);
drop function if exists pay_run_date(text);
create or replace function employee_change_group_of_request(p_field text)
returns text language sql immutable as $$
  select case p_field when 'name' then 'name' when 'kana' then 'name' when 'phone' then 'contact' when 'contact_email' then 'contact' when 'address' then 'address' when 'bank_account' then 'bank_account' else null end
$$;
drop table if exists payroll_transfer_account_snapshots;
drop function if exists payroll_transfer_account_snapshots_guard();
drop table if exists payroll_transfer_holds;
drop index if exists profile_change_requests_bank_pending;
drop index if exists profile_change_requests_bank_scheduled;
delete from profile_change_requests where field = 'wage';
update profile_change_requests set status = 'rejected' where status = 'cancelled';
alter table profile_change_requests drop constraint if exists profile_change_requests_apply_status_check;
alter table profile_change_requests drop constraint if exists profile_change_requests_field_check;
alter table profile_change_requests add constraint profile_change_requests_field_check check (field = any (array['name','kana','phone','address','bank_account','contact_email','id_document']));
alter table profile_change_requests drop constraint if exists profile_change_requests_status_check;
alter table profile_change_requests add constraint profile_change_requests_status_check check (status = any (array['pending','approved','rejected']));
alter table profile_change_requests drop column if exists payload, drop column if exists effective_date, drop column if exists effective_year_month, drop column if exists effective_pay_date,
  drop column if exists request_reason, drop column if exists apply_status, drop column if exists applied_at, drop column if exists apply_note, drop column if exists apply_ref, drop column if exists hq_task_id, drop column if exists notify_log;
update app_settings set value = value - 'bank_approval_required' - 'wage_approval_required' - 'pay_request_notify_enabled' - 'transfer_pending_mode' - 'transfer_guard_since' where key = 'employee_change';
-- ※ 申請時に作られた本部タスク（hq_tasks「口座変更／賃金変更の確認・承認」「【振込漏れ注意】…」）は残る。不要なら本部タスクボードで完了／削除する
