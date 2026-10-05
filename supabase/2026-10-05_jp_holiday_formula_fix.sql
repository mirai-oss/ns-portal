-- 2026-10-05: 祝日判定の取りこぼし修正（ユーザー承認「計算式への統一でお願いします」）
-- 2026-09-08_payroll_tasks_auto.sql の jp_is_holiday は
--   ・振替休日を「日曜の翌月曜」だけ判定（GWで火・水曜にずれる振替休日 例: 2031-05-06 を取りこぼす）
--   ・「国民の休日」（前後を祝日に挟まれた日 例: 2032-09-21）を非対応
-- だったため、祝日法どおりの判定に置き換える。jp_is_national_holiday（固定日・ハッピーマンデー・春分秋分）は変更なし。
-- 経営ダッシュボード(app.js jpHolidayName)・日報(index.html sfV12JpHolidayName)と同じロジック。3箇所は必ず揃えて直すこと。
-- 影響: jp_prev_business_day → hq_create_payroll_tasks（給与タスクの期日を直前営業日へ寄せる処理）。2045年までの差分は
--   2031-05-06 / 2032-09-21 / 2036-05-06 / 2037-05-06 / 2037-09-22 / 2042-05-06 / 2043-05-06 / 2043-09-22 の8日のみ。
create or replace function public.jp_is_holiday(p_date date)
returns boolean
language plpgsql
immutable
as $function$
declare v_p date;
begin
  if extract(dow from p_date)::int in (0,6) or jp_is_national_holiday(p_date) then
    return true;
  end if;
  -- 振替休日: 直前に連続する祝日の中に日曜があれば、その後の最初の「祝日でない日」が休日
  v_p := p_date - 1;
  while jp_is_national_holiday(v_p) loop
    if extract(dow from v_p)::int = 0 then return true; end if;
    v_p := v_p - 1;
  end loop;
  -- 国民の休日: 前日と翌日がともに祝日
  return jp_is_national_holiday(p_date - 1) and jp_is_national_holiday(p_date + 1);
end;
$function$;
