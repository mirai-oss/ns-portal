-- 戻し（関数のみ）
begin;

CREATE OR REPLACE FUNCTION public.apply_submit(p_form_key text, p_name text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_answers jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid; f applicant_forms%rowtype; v_dup boolean := false;
  v_prefs jsonb; v_ptxt text; v_ans jsonb;
begin
  select * into f from applicant_forms where key = p_form_key and is_active;
  if not found then raise exception 'フォームが見つかりません'; end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception '氏名を入力してください'; end if;
  if length(coalesce(p_name,'')) > 100 or length(coalesce(p_phone,'')) > 50
     or length(coalesce(p_email,'')) > 200 or pg_column_size(p_answers) > 100000 then
    raise exception '入力が長すぎます';
  end if;

  v_ans   := coalesce(p_answers,'{}'::jsonb);
  v_prefs := v_ans -> '_面接希望';                 -- v2.6.35 希望日時を取り出す
  if jsonb_typeof(v_prefs) is distinct from 'array' then v_prefs := null; end if;
  v_ptxt  := interview_prefs_text(v_prefs);
  -- 応募者カードで読めるように、日本語の1行も回答に残す
  if v_ptxt is not null then
    v_ans := v_ans || jsonb_build_object('面接の希望日時', v_ptxt);
  end if;

  -- v2.6.30 すでに同じ人がいれば、その人に足す（新しく作らない）
  v_id := applicant_match(p_name, p_phone, p_email);
  if v_id is not null then
    v_dup := true;
    update applicants set
      answers  = answers || v_ans,
      form_key = coalesce(form_key, p_form_key),
      phone    = coalesce(nullif(btrim(coalesce(phone,'')),''), nullif(btrim(coalesce(p_phone,'')),'')),
      email    = coalesce(nullif(btrim(coalesce(email,'')),''), nullif(btrim(coalesce(p_email,'')),'')),
      interview_prefs = coalesce(v_prefs, interview_prefs),
      form_received_at = now(),
      form_seen_at = null,
      updated_at = now()
     where id = v_id;
  else
    v_id := gen_random_uuid();
    insert into applicants (id, form_key, name, phone, email, source, answers, interview_prefs)
    values (v_id, p_form_key, trim(p_name),
            nullif(trim(coalesce(p_phone,'')),''), nullif(trim(coalesce(p_email,'')),''),
            'form', v_ans, v_prefs);
  end if;

  -- 採用担当へ通知（Lark・Chatworkにもこの本文がそのまま飛ぶ）
  insert into notifications (recipient_id, type, body_i18n, link)
  select u.id, 'applicant_new',
         jsonb_build_object('ja',
           case when v_dup then 'すでに登録がある方から応募がありました: '
                           else '新しい応募がありました: ' end
           || trim(p_name) || 'さん（' || f.title || '）'
           || case when v_ptxt is not null then E'\n面接の希望日時: ' || v_ptxt else '' end
           || case when coalesce(btrim(p_phone),'') <> '' then E'\n電話: ' || btrim(p_phone) else '' end),
         jsonb_build_object('applicant_id', v_id)
    from users u where u.is_active and has_feature(u.id, 'recruit');
  return v_id;
end $function$;

commit;
