-- =============================================================
-- 応急の手当て: 支払方法を「現金手渡し」に変えても、登録済みの口座の情報を消さない（2026-11-13 ユーザー承認。★本番未適用。適用は、報告のあと）
--   いま: 日報サイトの口座の保存は、現金のときに口座の欄を空（null）で上書きしていた。画面を直しても、別の画面や API から同じ上書きが来ると消える。
--   これから（DB の側の守り）:
--     ・口座の値が入っている行を、口座が空の内容で上書きしようとしたら、口座の列だけ元の値を残す（支払方法など、ほかの列の変更はそのまま通す）。
--     ・口座の行そのものを直接消すことも止める（従業員の削除にともなう連鎖の削除は通す）。
--     ・口座の情報をはっきり消したいときは、関数 payroll_bank_account_delete（本部・社長・マスターだけ。理由が必須。消す前の値を控えの表に残す）。
--   既存のデータは変えない（引き金 2 つ・関数 2 つ・控えの表 1 つを足すだけ）。既存の関数・ほかの表には触れない。
--   戻し方: 2026-11-23a_payroll_bank_keep_account_rollback.sql
-- =============================================================

-- 消した口座の控え（はっきり削除したときだけ入る。画面からは直接読めない）
create table if not exists public.payroll_bank_account_archive (
  id          bigserial primary key,
  user_id     uuid not null,
  account     jsonb not null,            -- 消す前の口座（金融機関・支店・種別・口座番号・名義）
  payment_method text,
  reason      text not null,
  deleted_by  uuid,
  deleted_at  timestamptz not null default now()
);
alter table public.payroll_bank_account_archive enable row level security;
revoke all on public.payroll_bank_account_archive from public, anon, authenticated;

create or replace function public.payroll_bank_keep_account()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(current_setting('payroll.bank_delete_ok', true), '') = '1' then return coalesce(new, old); end if;   -- はっきりした削除の操作のとき
  if tg_op = 'DELETE' then
    if pg_trigger_depth() <= 1 and old.account_number is not null then
      raise exception '口座の情報は、直接は消せません（従業員ページの「口座の情報を削除する」から、理由を入れて消してください）';
    end if;
    return old;
  end if;
  -- 口座が入っていたのに、空で上書きしようとしている: 口座の列は元の値を残す
  if old.account_number is not null and new.account_number is null then
    new.bank_code := old.bank_code; new.bank_name := old.bank_name; new.branch_code := old.branch_code; new.branch_name := old.branch_name;
    new.account_type := old.account_type; new.account_number := old.account_number; new.account_holder_kana := old.account_holder_kana;
  end if;
  return new;
end $$;
revoke all on function public.payroll_bank_keep_account() from public, anon, authenticated;
drop trigger if exists payroll_bank_keep_account on public.payroll_bank_accounts;
create trigger payroll_bank_keep_account before update or delete on public.payroll_bank_accounts
  for each row execute function public.payroll_bank_keep_account();

-- 口座の情報をはっきり消す（本部・社長・マスターだけ。理由が必須。行と支払方法は残し、口座の列だけ空にする。消す前の値は控えに残す）
create or replace function public.payroll_bank_account_delete(p_user uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare b payroll_bank_accounts%rowtype;
begin
  if not exists (select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO', 'HQ'))) then raise exception '権限がありません（本部・社長・マスターのみ）'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception '削除の理由を入れてください'; end if;
  select * into b from payroll_bank_accounts where user_id = p_user for update;
  if b.user_id is null or b.account_number is null then return jsonb_build_object('ok', true, 'unchanged', true); end if;
  insert into payroll_bank_account_archive(user_id, account, payment_method, reason, deleted_by)
  values (p_user, jsonb_build_object('bank_code', b.bank_code, 'bank_name', b.bank_name, 'branch_code', b.branch_code, 'branch_name', b.branch_name,
                                     'account_type', b.account_type, 'account_number', b.account_number, 'account_holder_kana', b.account_holder_kana),
          b.payment_method, left(btrim(p_reason), 500), auth.uid());
  -- 口座の「申請 → 承認」の関所（employee_change_pay_guard）が有効でも、この関数（権限と履歴つき）からの書き込みは通す
  perform set_config('employee_change.via_approval', 'payroll_bank_account_delete', true);
  perform set_config('payroll.bank_delete_ok', '1', true);
  update payroll_bank_accounts set bank_code = null, bank_name = null, branch_code = null, branch_name = null, account_number = null, account_holder_kana = null,
         updated_by = auth.uid(), updated_at = now() where user_id = p_user;
  perform set_config('payroll.bank_delete_ok', '', true);
  perform set_config('employee_change.via_approval', '', true);
  return jsonb_build_object('ok', true, 'deleted', true);
end $$;
revoke all on function public.payroll_bank_account_delete(uuid, text) from public, anon;
grant execute on function public.payroll_bank_account_delete(uuid, text) to authenticated;
