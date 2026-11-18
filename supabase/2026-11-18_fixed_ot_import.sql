-- 2026-11-18 固定残業代: スマレジの現在の値（読み取り）を、管理システムの月給の行の「基準」として取り込む。最小版（2026-12-13_fixed_ot_min.sql）の続き
--   hr_fixed_ot_import(p_items, p_actor): items = [{wage_id, state(none|applied), amount}]。本部・社長・マスターだけ。
--   hr_set_fixed_ot と同じ検査（月給の行だけ・金額 1〜10,000,000・時間数は既定 45 時間＝2700 分・承認が必須の設定のときは断る）。
--   基本給・適用開始日・同期の状態は変えない。スマレジへは何も送らない。変更は fixed_ot_changes に残す。
--   rollback: 2026-11-18_fixed_ot_import_rollback.sql（関数を消すだけ。入った値の戻しは fixed_ot_changes の before_value で行う）
create or replace function public.hr_fixed_ot_import(p_items jsonb, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_actor uuid; it jsonb; w employee_wage_settings%rowtype; v_cfg jsonb; n int := 0; v_state text; v_amount int;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select value into v_cfg from app_settings where key = 'employee_change';
  if coalesce((v_cfg ->> 'wage_approval_required')::boolean, false) then raise exception '賃金の変更は申請・承認が必要な設定です。ここからは取り込めません'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_state := it ->> 'state'; v_amount := nullif(it ->> 'amount', '')::int;
    if v_state not in ('none', 'applied') then raise exception '状態は none / applied のどちらかです'; end if;
    select * into w from employee_wage_settings where id = (it ->> 'wage_id')::uuid for update;
    if not found or w.division <> 2 then raise exception '月給の行が見つかりません'; end if;
    if v_state = 'applied' and (v_amount is null or v_amount < 1 or v_amount > 10000000) then raise exception '固定残業代の金額が不正です'; end if;
    if w.fixed_ot_state is distinct from 'unknown' then continue; end if;      -- すでに設定された行は上書きしない
    update employee_wage_settings set fixed_ot_state = v_state, fixed_ot_amount = case when v_state = 'applied' then v_amount end,
           fixed_ot_minutes = case when v_state = 'applied' then 2700 end, fixed_ot_set_by = v_actor, fixed_ot_set_at = now() where id = w.id;
    insert into fixed_ot_changes(wage_id, user_id, before_value, after_value, actor)
    values (w.id, w.user_id, jsonb_build_object('state', w.fixed_ot_state, 'amount', w.fixed_ot_amount, 'minutes', w.fixed_ot_minutes),
            jsonb_build_object('state', v_state, 'amount', case when v_state = 'applied' then v_amount end, 'minutes', case when v_state = 'applied' then 2700 end, 'source', 'smaregi_import'), v_actor);
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'imported', n);
end $$;
revoke all on function public.hr_fixed_ot_import(jsonb, uuid) from public, anon;
grant execute on function public.hr_fixed_ot_import(jsonb, uuid) to authenticated, service_role;
