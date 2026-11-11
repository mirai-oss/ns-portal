-- 休憩の自動補完: 給与形態の判定の追加（2026-11-13・その 2）
--   契約（法人）をまたいで異動した人: 新しい契約には「適用開始日なしの初期の時給の行」しか無く、月給は前の契約にだけ登録されている、という人が見つかった。
--   この場合、新しい契約での給与形態は決められない（月給が登録されていないだけの可能性が高い）ので、「時給」として対象外にせず、「決められない（確認の対象）」にする。
--   同じ理由で、その契約に賃金の登録が無く、ほかの契約にだけある人も「決められない」にする。
--   戻し方: 2026-11-13_break_autofill.sql の attendance_pay_type をもう一度流す（この関数だけ）。
create or replace function attendance_pay_type(p_user uuid, p_contract text, p_date date)
returns text language sql stable security definer set search_path = public as $$
  with cur as (select w.division, max(w.effective_date) d from employee_wage_settings w where w.user_id = p_user and w.contract_id = p_contract and w.effective_date <= p_date group by w.division),
  a as (select max(d) filter (where division = 0) h, max(d) filter (where division = 1) dy, max(d) filter (where division = 2) m from cur),
  o as (select exists (select 1 from employee_wage_settings w where w.user_id = p_user and w.contract_id <> p_contract and w.effective_date <= p_date and w.division in (1, 2)) other_non_hourly,
               exists (select 1 from employee_wage_settings w where w.user_id = p_user and w.contract_id <> p_contract and w.effective_date <= p_date) other_any)
  select case
    when exists (select 1 from wage_external_changes e where e.user_id = p_user and e.status = 'open')
      or exists (select 1 from profile_change_requests q where q.user_id = p_user and q.field = 'wage' and q.status = 'pending') then 'unapproved'
    when exists (select 1 from employee_wage_settings w where w.user_id = p_user and w.contract_id = p_contract and w.sync_status <> 'synced') then 'unsynced'
    when a.h is null and a.dy is null and a.m is null then case when o.other_any then 'ambiguous' else 'unknown' end
    when a.dy is not null and (a.m is not null or (a.h is not null and a.h <> date '1970-01-01')) then 'ambiguous'
    when a.dy is not null then 'daily'
    when a.m is not null and (a.h is null or a.h = date '1970-01-01' or a.m > a.h) then 'monthly'
    when a.m is not null then 'ambiguous'
    when a.h = date '1970-01-01' and o.other_non_hourly then 'ambiguous'   -- この契約には初期の時給の行だけ・月給（日給）はほかの契約にだけある
    else 'hourly' end
  from a, o
$$;
