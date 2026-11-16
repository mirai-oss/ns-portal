-- =============================================================
-- 勤怠修正申請: 一次承認者がいない店舗では、社長は「他人の」勤怠を申請できない（2026-11-16・社長の決定。担当D）
--   理由: 自分が出した申請は自分で最終承認できない（今までの規則）ため、承認者がいなくなる。申請の行を作る前に、案内を出して止める。
--   変えないもの: 社長本人の勤怠の申請（承認を省略して反映）／社長以外の人が出した申請（一次承認者がいない店では社長が直接承認）／一次承認者がいる店。
--   判定は DB（トリガー）で行う。画面・Slack の案内は、DB が返したメッセージをそのまま出すだけ。
-- ロールバック: 2026-12-12_attendance_request_president_guard_rollback.sql
-- =============================================================
create or replace function public.sf_attendance_requests_flow_init() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_set jsonb; v_route jsonb; v_role text;
begin
  select value into v_set from app_settings where key = 'attendance_request_flow';
  -- JSON の true とはっきり書いてあるときだけ ON（文字の "true" などは OFF 扱い。読めない値で申請を止めない）
  if coalesce((v_set -> 'thread') = 'true'::jsonb, false) and coalesce((v_set -> 'two_stage') = 'true'::jsonb, false)
     and new.flow is null and new.status = 'pending' then
    v_route := sf_attendance_request_route(new.store_id, new.requested_by, new.user_id);
    -- 2026-11-16（社長の決定）: 一次承認者がいない店舗で、社長が「他人の」勤怠を申請することはできない（自分が出した申請は自分で最終承認できないため、
    --   承認者がいなくなる）。申請の行を作る前に止める。社長本人の勤怠の申請・社長以外の人の申請は、今までどおり。判定は DB 側（申請者の役職）
    if v_route ->> 'stage' = 'final_wait' and nullif(v_route ->> 'first_approver_id', '') is null
       and new.requested_by is distinct from new.user_id then
      select role into v_role from users where id = new.requested_by and is_active;
      if coalesce(v_role, '') = 'CEO' then
        raise exception 'この店舗は一次承認者がいないため、社長からは申請できません。本人か店長から申請してください';
      end if;
    end if;
    new.flow := 'two_stage';
    new.stage := v_route ->> 'stage';
    new.first_approver_id := nullif(v_route ->> 'first_approver_id', '')::uuid;
    new.first_skipped := coalesce((v_route ->> 'first_skipped')::boolean, false);
    if new.stage = 'final_wait' then new.final_requested_at := now(); end if;
  end if;
  return new;
end $$;
