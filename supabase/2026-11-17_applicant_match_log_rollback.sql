-- 2026-11-17_applicant_match_log.sql の戻し（applicant_match を 2026-11-12 時点の本番の定義に戻す。記録の表は残す＝害が無いため。消すなら drop table applicant_match_log）
CREATE OR REPLACE FUNCTION public.applicant_match(p_name text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  -- ① 電話番号（いちばん確実）
  if norm_phone(p_phone) is not null then
    select id into v_id from applicants
     where user_id is null and norm_phone(phone) = norm_phone(p_phone)
     order by applied_at desc limit 1;
    if v_id is not null then return v_id; end if;
  end if;
  -- ② メールアドレス
  if nullif(btrim(coalesce(p_email,'')),'') is not null then
    select id into v_id from applicants
     where user_id is null and lower(btrim(email)) = lower(btrim(p_email))
     order by applied_at desc limit 1;
    if v_id is not null then return v_id; end if;
  end if;
  -- ③ 氏名（表記ゆれを吸収して比較）
  if norm_name(p_name) is not null then
    select id into v_id from applicants
     where user_id is null and norm_name(name) = norm_name(p_name)
     order by applied_at desc limit 1;
    if v_id is not null then return v_id; end if;
  end if;
  return null;
end $function$;

drop function if exists public.applicant_match_core(text, text, text);
