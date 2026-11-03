-- 【事前報告様式（DB変更）】
-- 目的: アルバイト人件費（labor_cost_daily）を、スマレジの「労働実績」＝月次給与明細(sf_payroll_sync)の総支給額に合わせて日次に按分する（担当A・2026-11-03・ユーザー指示）。
--   従来: labor_cost_dailyの金額=スマレジAPIの日次概算(smaregi_estimate_cost)をそのまま使用 → 勤務明細CSV(スプレッドシート経路)より約5〜10%少ない
--         （9月実測: 概算 8,085,099円 / スプレッドシート 8,992,740円。概算は交通費などを含まない）。
--   新:   (人×月)ごとに係数 = その月の総支給額(total_allowance。契約をまたぐ兼務は合算) ÷ その人のその月の概算合計 を求め、
--         各行の computed_cost = 概算 × 係数 を保存。経営DのGAS(bqApplyApiLaborCostRow_)は computed_cost があればそれを使う（既存の挙動・GAS変更なし）。
--   給与明細が無い・概算合計が0・係数が0.6〜1.6の範囲外（異常値）の行は computed_cost=NULL（＝従来どおり概算）。
--   対象はSHAIN/TENCHO以外（社員の給与は別ルート）。
-- 追加（新規のみ・既存テーブルの列変更なし）: RPC labor_cost_apply_payroll(p_ym text)（service_roleのみ）
-- ロールバック: update labor_cost_daily set computed_cost = null where work_date >= '2026-10-01'; drop function labor_cost_apply_payroll(text);
-- 実行: supabase db query --linked -f supabase/2026-11-03_labor_cost_apply_payroll.sql

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
    from public.labor_cost_daily l join public.users u on u.id = l.user_id
    where l.work_date >= v_from and l.work_date < v_to and u.role not in ('SHAIN', 'TENCHO')),
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
comment on function public.labor_cost_apply_payroll(text) is '月次給与明細の総支給額に合わせて labor_cost_daily.computed_cost を日次に按分（アルバイト人件費の労働実績ベース化・2026-11-03）';
