-- 2026-11-15 担当A: 「給与・インセンティブ配分」画面に、その月に月給の人だけを出すための関数（ユーザー指示 2026-11-15）。
--   月給の判定 = labor_is_monthly（給与設定の適用開始日つき。月末時点で月給なら、その月から表示＝途中から社員になった人はその月から出る）。
--   過去にアルバイトだった月は出さない。ただし、その月まで（その月を含む）に配分の金額（0円以外）を保存したことがある人は出す（給与設定が無い本部・チーム長の入力画面を消さないため）。
--   マスターのみ。読み取り専用。
-- 【rollback】drop function public.payroll_monthly_user_ids(text);
create or replace function public.payroll_monthly_user_ids(p_ym text) returns setof uuid
language plpgsql stable security definer set search_path to 'public' as $$
declare v_end date;
begin
  if not public.me_is_master() then raise exception 'マスターのみ'; end if;
  if p_ym is null or p_ym !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'p_ymはYYYY-MM'; end if;
  v_end := ((p_ym || '-01')::date + interval '1 month - 1 day')::date;
  return query
    select u.id from public.users u where public.labor_is_monthly(u.id, v_end)
    union
    select a.user_id from public.sf_payroll_allocations a where a.period_key <= p_ym and coalesce(a.amount, 0) <> 0;   -- 配分を一度でも保存した月以降の人（給与設定が無い本部・チーム長など。例: 佐藤俊一・鍋倉巧）も出す
end
$$;
revoke all on function public.payroll_monthly_user_ids(text) from public, anon;
grant execute on function public.payroll_monthly_user_ids(text) to authenticated;
