-- 2026-11-15 担当A: 人件費のアルバイト／社員の振り分けを「その日に月給かどうか」で判定する（ユーザー指示 2026-11-15）。
-- 背景: これまでは「現在の区分(users.role)」で全期間を判定していたため、アルバイトから社員に変わった人（例: AYE THIRI ZAW 11/1から月給）の
--   アルバイト時期の分が、社員の人件費（スマレジの給与明細の予備計上）に入ってしまっていた（本店10月: PA −278,618／社員 +315,027）。
-- 方針:
--   ・月給の判定 = employee_wage_settings の適用開始日つき設定で、その日に有効な設定の区分が 2（月給）。設定が適用前のときは最も古い設定の区分を使う
--     （もともと月給の人は登録日より前も月給。例: 青山純）。月給以外（設定なし含む）は全員アルバイト。
--   ・アルバイト人件費 = labor_cost_daily（スマレジ API）の computed_cost（給与明細で補正済み）、無ければ smaregi_estimate_cost。月給の人の打刻金額は取らない。
--   ・社員人件費 = 管理システムの「社員給料・インセンティブ配分」(sf_payroll_allocations)のみ。スマレジ給与明細からの予備計上はしない。
--       日割り=月合計÷暦日数、法定福利費=（基本給+インセンティブ+賞与）×15%、通勤手当は日割り（GASの旧計算 bqApplyApiLaborCostRow_ と同じ）。
-- 追加: 関数 labor_is_monthly / labor_split_daily（読み取り専用・service_role 限定）。labor_cost_apply_payroll は月給判定を日付ベースに変更（role判定をやめる）。
-- 【rollback】labor_cost_apply_payroll を 2026-11-03_labor_cost_apply_payroll.sql の定義に戻し、drop function labor_split_daily(date,date), labor_is_monthly(uuid,date)。

create or replace function public.labor_is_monthly(p_user uuid, p_date date) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce(
    (select w.division from public.employee_wage_settings w where w.user_id = p_user and w.effective_date <= p_date order by w.effective_date desc limit 1),
    (select w.division from public.employee_wage_settings w where w.user_id = p_user order by w.effective_date asc limit 1),
    0) = 2
$$;
revoke all on function public.labor_is_monthly(uuid,date) from public, anon, authenticated;
grant execute on function public.labor_is_monthly(uuid,date) to service_role;

-- 店舗×日の人件費の内訳（2026-10-01以降）。アルバイト＝打刻（月給でない人）、社員＝配分（月合計を暦日割り）。
create or replace function public.labor_split_daily(p_from date, p_to date) returns table(
  store_id uuid, work_date date, pa numeric, emp_salary numeric, emp_statutory numeric, emp_commute numeric, emp_total numeric)
language sql stable security definer set search_path to 'public' as $$
  with rng as (select greatest(p_from, date '2026-10-01') f, p_to t),
  pa as (
    select l.store_id, l.work_date, sum(coalesce(l.computed_cost, l.smaregi_estimate_cost, 0)) cost
      from public.labor_cost_daily l, rng
     where l.work_date between rng.f and rng.t and not public.labor_is_monthly(l.user_id, l.work_date)
     group by 1, 2),
  al as (
    select a.store_id, substr(a.period_key, 1, 7) ym,
           sum(a.amount) filter (where a.kind <> 'commute') sal, sum(a.amount) filter (where a.kind = 'commute') com
      from public.sf_payroll_allocations a where a.period_key >= '2026-10' group by 1, 2),
  days as (select (rng.f + g)::date d from rng, generate_series(0, greatest(rng.t - rng.f, 0)) g where rng.t >= rng.f),
  keys as (select store_id, work_date d from pa union select al.store_id, days.d from al join days on to_char(days.d, 'YYYY-MM') = al.ym)
  select k.store_id, k.d,
         coalesce(pa.cost, 0),
         coalesce(al.sal, 0) / dim.n,
         coalesce(al.sal, 0) / dim.n * 0.15,
         coalesce(al.com, 0) / dim.n,
         coalesce(al.sal, 0) / dim.n * 1.15 + coalesce(al.com, 0) / dim.n
    from keys k
    cross join lateral (select extract(day from (date_trunc('month', k.d) + interval '1 month - 1 day'))::numeric n) dim
    left join pa on pa.store_id = k.store_id and pa.work_date = k.d
    left join al on al.store_id = k.store_id and al.ym = to_char(k.d, 'YYYY-MM')
$$;
revoke all on function public.labor_split_daily(date,date) from public, anon, authenticated;
grant execute on function public.labor_split_daily(date,date) to service_role;

-- 給与明細ベースの補正（labor_cost_apply_payroll）: 対象を「role が SHAIN/TENCHO 以外」から「その日に月給でない人」に変更（他は 2026-11-03 の定義のまま）。
do $guard$
declare v_src text;
begin
  select prosrc into v_src from pg_proc where proname = 'labor_cost_apply_payroll' and pronamespace = 'public'::regnamespace;
  if v_src is null or v_src not like '%u.role not in (''SHAIN'', ''TENCHO'')%' then
    raise exception 'labor_cost_apply_payroll が想定の状態ではありません（未作成 or 変更済み）。中止します';
  end if;
end
$guard$;

create or replace function public.labor_cost_apply_payroll(p_ym text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_claims jsonb; v_from date; v_to date; n_set int := 0; n_null int := 0;
begin
  begin v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb; exception when others then v_claims := null; end;
  if coalesce(v_claims->>'role','') <> 'service_role' then return jsonb_build_object('ok', false, 'error', 'service_roleのみ'); end if;
  if p_ym is null or p_ym !~ '^\d{4}-(0[1-9]|1[0-2])$' then return jsonb_build_object('ok', false, 'error', 'p_ymはYYYY-MM'); end if;
  v_from := (p_ym || '-01')::date; v_to := (v_from + interval '1 month')::date;

  with est as (
    select l.id, l.user_id, coalesce(l.smaregi_estimate_cost, 0) c
    from public.labor_cost_daily l
    where l.work_date >= v_from and l.work_date < v_to and not public.labor_is_monthly(l.user_id, l.work_date)),
  tot as (select user_id, sum(c) sc from est group by user_id),
  pay as (select user_id, sum(total_allowance) ta from public.sf_payroll_sync where year_month = p_ym group by user_id),
  calc as (
    select e.id, e.c, t.sc, p.ta,
      case when t.sc > 0 and p.ta > 0 and (p.ta / t.sc) between 0.6 and 1.6 then round(e.c * p.ta / t.sc) else null end as newcost
    from est e join tot t using (user_id) left join pay p using (user_id))
  update public.labor_cost_daily l set computed_cost = c.newcost, updated_at = now()
    from calc c where l.id = c.id and l.computed_cost is distinct from c.newcost;
  get diagnostics n_set = row_count;
  return jsonb_build_object('ok', true, 'year_month', p_ym, 'rows_changed', n_set);
end $$;
revoke all on function public.labor_cost_apply_payroll(text) from public, anon, authenticated;
grant execute on function public.labor_cost_apply_payroll(text) to service_role;
