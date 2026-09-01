-- ============================================================
-- 緊急バグ修正: 個人情報変更申請が「従業員情報が見つかりません」で
-- 誰にも使えなかった不具合（2026-09-02・担当F）
-- 実行場所: Supabase SQL Editor（何度実行しても壊れません）
--
-- 原因判明: requests.htmlの「個人情報変更」はinfo.employees（ns-info-system側の
-- 小さな別テーブル・在籍14名中アクティブわずか3名・portal_user_id紐付け0件）を
-- 参照していた。実際の全社員（スマレジ連携込み）はハブのpublic.employee_profiles
-- （public.users.idと1:1・全員が最初から持っている）にある。info.employeesは
-- 役員名簿など別目的の小さな管理テーブルであり、一般社員の個人情報とは無関係だった。
--
-- 対応: 個人情報変更（氏名・フリガナ・電話番号・住所・連絡用メール・銀行口座・
-- 身分証明書）は、ハブのpublic.employee_profiles/public.usersを直接対象にする
-- 新しいテーブル・関数一式に作り直す（info.employees版は残置・無効化はしない
-- が今後この用途では使わない）。承認者の定義もpublic.users.is_master/role='HQ'
-- （ポータル自身の役職）に統一する（info.profilesの役職とは別物で二重管理に
-- なっていたのも解消）。
-- 社内システムのID/PW変更申請（credentials関連）は対象データがns-info-system
-- 側で正しいため今回は無変更。
-- ============================================================

set search_path to public;

create table if not exists profile_change_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  field text not null check (field in ('name','kana','phone','address','bank_account','contact_email','id_document')),
  old_value text,
  new_value text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  requested_by uuid not null references users(id),
  requested_at timestamptz not null default now(),
  reviewed_by uuid references users(id),
  reviewed_at timestamptz,
  reject_reason text
);
comment on table profile_change_requests is
  '本人（アルバイト含む全員）による個人情報変更申請。承認されるとpublic.users/employee_profiles/payroll_bank_accountsへ反映される。行自体が履歴を兼ねる（削除しない）';

alter table profile_change_requests enable row level security;

drop policy if exists pcr_admin_all on profile_change_requests;
create policy pcr_admin_all on profile_change_requests for all using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role = 'HQ'))
);

drop policy if exists pcr_read_own on profile_change_requests;
create policy pcr_read_own on profile_change_requests for select using (requested_by = auth.uid());

-- 承認者判定（マスター or 役職HQ＝本部。ポータル自身のusers.roleで統一）
create or replace function is_profile_approver()
returns boolean language sql stable security definer
set search_path to 'public' as $$
  select coalesce((
    select u.is_master or u.role = 'HQ'
    from users u where u.id = auth.uid() and u.is_active
  ), false);
$$;

-- 申請の作成（本人のみ・対象は常に自分自身）
create or replace function submit_profile_change_request(
  p_field text,
  p_new_value text
) returns uuid language plpgsql security definer
set search_path to 'public' as $$
declare
  v_old text;
  v_req_id uuid;
  v_name text;
begin
  if p_field not in ('name','kana','phone','address','bank_account','contact_email','id_document') then
    raise exception '不正な項目です';
  end if;
  if p_new_value is null or btrim(p_new_value) = '' then
    raise exception '新しい値を入力してください';
  end if;

  select name into v_name from users where id = auth.uid() and is_active;
  if v_name is null then
    raise exception 'ログイン情報が確認できませんでした';
  end if;

  if p_field = 'bank_account' then
    begin perform p_new_value::jsonb;
    exception when others then raise exception '口座情報の形式が不正です'; end;
    select to_jsonb(pba) into v_old from payroll_bank_accounts pba where pba.user_id = auth.uid();
  elsif p_field = 'id_document' then
    begin perform p_new_value::jsonb;
    exception when others then raise exception '身分証明書の情報の形式が不正です'; end;
    v_old := null;
  elsif p_field = 'name' then
    v_old := v_name;
  elsif p_field = 'kana' then
    select name_kana into v_old from employee_profiles where user_id = auth.uid();
  elsif p_field = 'phone' then
    select phone into v_old from employee_profiles where user_id = auth.uid();
  elsif p_field = 'address' then
    select address into v_old from employee_profiles where user_id = auth.uid();
  elsif p_field = 'contact_email' then
    select extra->>'contact_email' into v_old from employee_profiles where user_id = auth.uid();
  end if;

  insert into profile_change_requests (user_id, field, old_value, new_value, requested_by)
  values (auth.uid(), p_field, v_old, p_new_value, auth.uid())
  returning id into v_req_id;

  return v_req_id;
end $$;

-- 申請の承認／却下
create or replace function review_profile_change_request(
  p_request_id uuid,
  p_approve boolean,
  p_reason text default null
) returns void language plpgsql security definer
set search_path to 'public' as $$
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
end $$;

-- 自分の口座がすでに登録済みかどうか（フォーム側の案内表示用。値そのものは返さない）
create or replace function has_my_bank_account()
returns boolean language sql stable security definer
set search_path to 'public' as $$
  select exists(select 1 from payroll_bank_accounts where user_id = auth.uid());
$$;
