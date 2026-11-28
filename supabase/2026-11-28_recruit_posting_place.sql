-- 2026-11-28 採用: 同じ求人タイトルが別の勤務地でも使われると、店舗を取り違える不具合の修正
--   原因: indeed_intake が「求人タイトル」だけで店舗を決めていた（job_postings.title_key）。
--   直し: メールの店舗名が登録と違うときは、別の行（title_key = タイトル@店舗名）を使う。未登録なら店舗は空。
--   戻し方: 2026-11-28_recruit_posting_place_rollback.sql
begin;

create or replace function public.job_posting_key(p_title text, p_hint text) returns text
language sql stable security definer set search_path = public as $function$
  select case
    when job_title_key(p_title) is null then null
    when job_title_key(p_hint) is not null and exists (
           select 1 from job_postings j
            where j.title_key = job_title_key(p_title)
              and job_title_key(j.store_hint) is not null
              and job_title_key(j.store_hint) <> job_title_key(p_hint))
      then job_title_key(p_title) || '@' || job_title_key(p_hint)
    else job_title_key(p_title)
  end
$function$;
revoke execute on function public.job_posting_key(text,text) from public, anon, authenticated;

create or replace FUNCTION public.indeed_intake(p_secret text, p_name text, p_job text DEFAULT NULL::text, p_location text DEFAULT NULL::text, p_store text DEFAULT NULL::text, p_contact text DEFAULT NULL::text, p_mail_id text DEFAULT NULL::text, p_applied_at timestamp with time zone DEFAULT now(), p_url text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_tkey text; v_form_key text; v_store_id uuid; v_ans jsonb; v_pkey text;
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
    -- 同じ求人タイトルでも、メールの店舗名が違うときは別の行（勤務地つき）にする。
    -- 店舗は空のまま作り、「求人タイトルの登録」で人が一度だけ決める（別の店舗に自動で入れない）。
    v_pkey := job_posting_key(p_job, p_store);
    if v_pkey <> v_tkey then
      insert into job_postings (title, title_key, store_hint, form_key)
      select btrim(p_job) || '｜' || coalesce(nullif(btrim(coalesce(p_location,'')),''), btrim(p_store)),
             v_pkey, btrim(p_store), j.form_key
        from job_postings j where j.title_key = v_tkey
      on conflict (title_key) do nothing;
    end if;
    select form_key, store_id into v_form_key, v_store_id
      from job_postings where title_key = v_pkey;
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
   where j.title_key = job_posting_key(coalesce(nullif(btrim(a.job_type),''), a.answers->>'求人'), a.answers->>'店舗')
     and ((a.form_key is null and j.form_key is not null)
       or (a.store_id is null and j.store_id is not null));
  get diagnostics v_n = row_count;
  return v_n;
end $function$;

-- 今回の1件の直し: 川崎の「匠味」の行を作って店舗を決め、取り違えた応募者の店舗を直す
insert into job_postings (title, title_key, store_hint, form_key, store_id)
select '和食料理屋　店内スタッフ｜神奈川県 川崎市 川崎区 砂子', job_posting_key('和食料理屋　店内スタッフ', '有限会社トーホーエージェンシー　匠味'), '有限会社トーホーエージェンシー　匠味', 'al', s.id
  from stores s where s.name = '鶏武者 川崎店'
on conflict (title_key) do update set store_id = excluded.store_id, updated_at = now();

update applicants set store_id = (select id from stores where name = '鶏武者 川崎店'), updated_at = now()
 where id = '93fc6835-508a-4c8e-8de1-eb29b8e815c1'
   and store_id = (select id from stores where name = '黒霧屋 新横浜');

commit;
