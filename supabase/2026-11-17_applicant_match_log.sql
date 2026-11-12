-- =============================================================
-- 応募者の照合: 新しい判定の「記録だけ」の段階（2026-11-12 ユーザー決定）
--   いま: 取り込みのとき、電話番号 → メール → 氏名（表記ゆれを吸収して同じ）の順で既存の応募者を探し、見つかればその人に足している。
--         Indeed の取り込みは氏名だけを渡すため、氏名だけの一致でも同じ人として扱っている。
--   方針: 氏名だけの一致では自動で同じ人にしない（人の確認待ちにする）。その前に、まず影響を確かめる。
--   この文でやること（★動きは今までと同じ）:
--     ・いまの照合の中身を、そのまま applicant_match_core に移す（1 文字も変えない）。
--     ・applicant_match は、core を呼んで同じ結果を返し、そのとき「どの条件で一致したか」「新しい判定ならどうなるか」を applicant_match_log に 1 行残す。
--       記録に失敗しても、照合の結果はそのまま返す（取り込みを止めない）。
--     ・記録に入れるのは、応募者の ID と真偽だけ。氏名・電話番号・メールアドレスは入れない。
--   新しい判定（記録するだけ。まだ使わない）:
--     auto    … 電話番号かメールが一致し、氏名も同じ（＝同じ応募者。再応募として新しい採用案件にする候補）
--     confirm … 氏名だけの一致／電話番号かメールは一致するが氏名が違う（＝人の確認待ちにする候補）
--     new     … どれにも一致しない（＝新しい応募者）
--   戻し方: 2026-11-17_applicant_match_log_rollback.sql
-- =============================================================
do $$ begin
  if (select md5(prosrc) from pg_proc where proname = 'applicant_match' and pronamespace = 'public'::regnamespace) <> '4265b791ab3c596a642402ce33f8d4a0'
     and to_regprocedure('public.applicant_match_core(text,text,text)') is null then
    raise exception 'applicant_match の本番の定義が、基準（2026-11-12 に確認したもの）と違います。適用を中止します';
  end if;
end $$;

create table if not exists public.applicant_match_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  matched_id uuid,                 -- いまの照合が返した応募者（無ければ null）
  rule text not null check (rule in ('phone', 'email', 'name', 'none')),   -- いまの照合が、どの条件で一致したか
  had_phone boolean not null, had_email boolean not null, had_name boolean not null,   -- 取り込みが渡してきた項目
  phone_id uuid, email_id uuid, name_id uuid,   -- それぞれの条件で見つかる応募者
  name_same boolean,               -- 電話番号・メールで見つかった応募者と、氏名（表記ゆれを吸収）が同じか
  new_decision text not null check (new_decision in ('auto', 'confirm', 'new')),   -- 新しい判定ならどうなるか
  differs boolean not null         -- 新しい判定にすると、いまと動きが変わるか（＝いまは同じ人に足すが、新しい判定では確認待ちになる）
);
alter table public.applicant_match_log enable row level security;   -- ポリシーなし＝画面からは読めない
revoke all on public.applicant_match_log from anon, authenticated;
create index if not exists applicant_match_log_at on public.applicant_match_log(at desc);

-- いまの照合の中身（そのまま。名前だけ変えたもの）
CREATE OR REPLACE FUNCTION public.applicant_match_core(p_name text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text)
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

revoke all on function public.applicant_match_core(text, text, text) from public, anon, authenticated;
grant execute on function public.applicant_match_core(text, text, text) to service_role;

-- 包み: 返す値は core と同じ。判定の内訳を記録する（記録が失敗しても結果は返す）
create or replace function public.applicant_match(p_name text, p_phone text default null, p_email text default null)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_phone uuid; v_email uuid; v_name uuid; v_rule text; v_same boolean; v_new text;
begin
  v_id := applicant_match_core(p_name, p_phone, p_email);
  begin
    if norm_phone(p_phone) is not null then
      select id into v_phone from applicants where user_id is null and norm_phone(phone) = norm_phone(p_phone) order by applied_at desc limit 1;
    end if;
    if nullif(btrim(coalesce(p_email, '')), '') is not null then
      select id into v_email from applicants where user_id is null and lower(btrim(email)) = lower(btrim(p_email)) order by applied_at desc limit 1;
    end if;
    if norm_name(p_name) is not null then
      select id into v_name from applicants where user_id is null and norm_name(name) = norm_name(p_name) order by applied_at desc limit 1;
    end if;
    v_rule := case when v_id is null then 'none' when v_id = v_phone then 'phone' when v_id = v_email then 'email' when v_id = v_name then 'name' else 'none' end;
    if v_rule in ('phone', 'email') then
      select norm_name(a.name) is not distinct from norm_name(p_name) into v_same from applicants a where a.id = v_id;
    end if;
    v_new := case when v_id is null then 'new' when v_rule in ('phone', 'email') and coalesce(v_same, false) then 'auto' else 'confirm' end;
    insert into applicant_match_log(matched_id, rule, had_phone, had_email, had_name, phone_id, email_id, name_id, name_same, new_decision, differs)
    values (v_id, v_rule, norm_phone(p_phone) is not null, nullif(btrim(coalesce(p_email, '')), '') is not null, norm_name(p_name) is not null,
            v_phone, v_email, v_name, v_same, v_new, v_id is not null and v_new = 'confirm');
  exception when others then
    raise warning 'applicant_match_log: %', sqlerrm;   -- 記録できなくても、照合の結果は返す
  end;
  return v_id;
end $$;
-- 実行できる人は、今までと同じ（変えない）
