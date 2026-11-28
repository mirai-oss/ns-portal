-- 2026-11-28_recruit_posting_place.sql の戻し
begin;
create or replace FUNCTION public.indeed_intake(p_secret text, p_name text, p_job text DEFAULT NULL::text, p_location text DEFAULT NULL::text, p_store text DEFAULT NULL::text, p_contact text DEFAULT NULL::text, p_mail_id text DEFAULT NULL::text, p_applied_at timestamp with time zone DEFAULT now(), p_url text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_tkey text; v_form_key text; v_store_id uuid; v_ans jsonb;
begin
  if not public.recruit_intake_secret_ok(p_secret) then
    raise sqlstate 'PT403' using message = '認証エラー';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception '氏名がありません'; end if;
  -- 同じメールを二度取り込まない
  if p_mail_id is not null and exists(select 1 from applicants where source_ref = p_mail_id) then
    return null;
  end if;

  v_tkey := job_title_key(p_job);
  if v_tkey is not null then
    insert into job_postings (title, title_key, store_hint)
    values (btrim(p_job), v_tkey, nullif(btrim(coalesce(p_store,'')),''))
    on conflict (title_key) do update
      set store_hint = coalesce(job_postings.store_hint, excluded.store_hint);
    select form_key, store_id into v_form_key, v_store_id
      from job_postings where title_key = v_tkey;
  end if;

  v_ans := jsonb_strip_nulls(jsonb_build_object(
    '求人', nullif(trim(coalesce(p_job,'')),''),
    '勤務地', nullif(trim(coalesce(p_location,'')),''),
    '店舗', nullif(trim(coalesce(p_store,'')),''),
    'Indeed連絡先', nullif(trim(coalesce(p_contact,'')),'')));

  -- v2.6.30 すでに同じ人がいれば、その人に足す（新しく作らない）
  v_id := applicant_match(p_name, null, null);
  if v_id is not null then
    update applicants set
      answers    = answers || v_ans,          -- 新しい求人情報で上書き（応募し直しのため）
      indeed_url = coalesce(p_url, indeed_url),
      job_type   = coalesce(nullif(trim(coalesce(p_job,'')),''), job_type),
      form_key   = coalesce(form_key, v_form_key),
      store_id   = coalesce(store_id, v_store_id),
      updated_at = now()
     where id = v_id;
    insert into notifications (recipient_id, type, body_i18n, link)
    select u.id, 'applicant_new',
           jsonb_build_object('ja', 'すでに登録がある方がIndeedから再応募: ' || trim(p_name) || 'さん'),
           jsonb_build_object('applicant_id', v_id)
      from users u where u.is_active and can_see_applicant(u.id, (select store_id from applicants where id = v_id));
    return v_id;
  end if;

  v_id := gen_random_uuid();
  insert into applicants (id, name, source, source_ref, job_type, applied_at, answers, indeed_url,
                          form_key, store_id)
  values (v_id, trim(p_name), 'indeed', p_mail_id,
          nullif(trim(coalesce(p_job,'')),''), coalesce(p_applied_at, now()),
          v_ans, nullif(trim(coalesce(p_url,'')),''), v_form_key, v_store_id);
  insert into notifications (recipient_id, type, body_i18n, link)
  select u.id, 'applicant_new',
         jsonb_build_object('ja', 'Indeedから新しい応募: ' || trim(p_name) || '（' || coalesce(nullif(trim(coalesce(p_job,'')),''), '求人') || '）'),
         jsonb_build_object('applicant_id', v_id)
    from users u where u.is_active and can_see_applicant(u.id, v_store_id);
  return v_id;
end $function$;

create or replace function public.job_postings_apply() returns integer
language plpgsql security definer set search_path to 'public' as $function$
declare v_n int := 0;
begin
  if not has_feature(auth.uid(),'recruit_all') then raise exception '全店舗の権限が必要です'; end if;
  update applicants a set
     form_key = coalesce(a.form_key, j.form_key),
     store_id = coalesce(a.store_id, j.store_id),
     updated_at = now()
    from job_postings j
   where j.title_key = job_title_key(coalesce(nullif(btrim(a.job_type),''), a.answers->>'求人'))
     and ((a.form_key is null and j.form_key is not null)
       or (a.store_id is null and j.store_id is not null));
  get diagnostics v_n = row_count;
  return v_n;
end $function$;

update applicants set store_id = (select id from stores where name = '黒霧屋 新横浜'), updated_at = now()
 where id = '93fc6835-508a-4c8e-8de1-eb29b8e815c1' and store_id = (select id from stores where name = '鶏武者 川崎店');
delete from job_postings where title_key like '%@%';
drop function if exists public.job_posting_key(text,text);
commit;
