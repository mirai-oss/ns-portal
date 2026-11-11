-- 共通承認基盤（2026-11-11_approval_base.sql）を完全に外す  ★実行は別途承認
--   通常の「戻す」は 2026-11-11_approval_wage_route_off.sql（ルートを無効にするだけ・履歴は残る）で足りる。この SQL は表ごと消す最終手段。
--   既存の関数・表は 1 つも作り替えていないので、外せば 2026-11-10_pay_change_requests.sql の動きにそのまま戻る。
--   進行中の案件があるときは止まる。消える履歴（案件・操作の履歴）は、実行前に控えを取ること。
do $$
declare n int;
begin
  if to_regclass('public.approval_cases') is not null then
    execute 'select count(*) from approval_cases where status in (''pending'', ''returned'')' into n;
    if n > 0 then raise exception '進行中の案件が % 件あります。先に 0 件にしてください', n; end if;
  end if;
end $$;
drop trigger if exists approval_request_guard on profile_change_requests;
drop trigger if exists pay_change_request_approval_case on profile_change_requests;
drop trigger if exists approval_wage_target_guard on employee_wage_settings;
drop function if exists hr_approval_overview(uuid, boolean);
drop function if exists hr_approval_act(uuid, text, text, uuid, jsonb);
drop function if exists approval_case_json(uuid, uuid);
drop function if exists approval_request_after();
drop function if exists approval_request_guard();
drop function if exists approval_wage_target_guard();
drop function if exists approval_finalize_wage(uuid, uuid, boolean, text);
drop function if exists approval_task_relabel(uuid);
drop function if exists approval_task_sync(uuid, uuid, text);
drop function if exists approval_cases_backfill();
drop function if exists approval_case_open(uuid, text);
drop function if exists approval_can_act(uuid, uuid);
drop function if exists approval_stage_due(jsonb, integer, date, timestamptz);
drop function if exists approval_close_info(uuid, date, integer, date);
drop function if exists approval_via(jsonb);
drop function if exists approval_resolve_actor(uuid);
drop function if exists approval_role_label(jsonb);
drop function if exists approval_route_active(text, text);
drop table if exists approval_actions;
drop table if exists approval_cases;
drop table if exists approval_routes;
drop function if exists approval_routes_after();
drop function if exists approval_routes_guard();
drop function if exists approval_actions_guard();
