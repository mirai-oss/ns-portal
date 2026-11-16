-- ロールバック: 社長の他人申請の遮断を外す（元の関数本体に戻す）
create or replace function public.sf_attendance_requests_flow_init() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_set jsonb; v_route jsonb;
begin
  select value into v_set from app_settings where key = 'attendance_request_flow';
  -- JSON の true とはっきり書いてあるときだけ ON（文字の "true" などは OFF 扱い。読めない値で申請を止めない）
  if coalesce((v_set -> 'thread') = 'true'::jsonb, false) and coalesce((v_set -> 'two_stage') = 'true'::jsonb, false)
     and new.flow is null and new.status = 'pending' then
    v_route := sf_attendance_request_route(new.store_id, new.requested_by, new.user_id);
    new.flow := 'two_stage';
    new.stage := v_route ->> 'stage';
    new.first_approver_id := nullif(v_route ->> 'first_approver_id', '')::uuid;
    new.first_skipped := coalesce((v_route ->> 'first_skipped')::boolean, false);
    if new.stage = 'final_wait' then new.final_requested_at := now(); end if;
  end if;
  return new;
end $$;
