-- =====================================================================
-- 内部連携シークレットのローテーション（続き） — データ基盤Day2 タスクMac mini側
-- =====================================================================
-- 2026-08-21_intake_secret_rotation.sql の続き。smaregi-sync/index.ts の
-- ソースをリポジトリへ初めてバックアップした際に、同じ合言葉を使う関数が
-- さらに6つDB上に存在し（いずれもリポジトリのSQLファイルに未保存）、
-- smaregi-sync自身のnotify_chatworkアクションにもハードコードがあることが
-- 判明。まとめて修正する（checklist_intake_secret_ok()は
-- 2026-08-21_intake_secret_rotation.sqlで定義済み・新旧両対応）。
--
-- 対象: migrate_intake / indeed_message_intake / indeed_fill_url /
--       indeed_intake / form_intake（いずれも採用管理の外部連携用・
--       Indeed/フォーム/CSV移行の取込口） / notify_route_send（Chatwork/Lark中継）
-- 実行場所: Supabase SQL Editor / Management API
-- =====================================================================

create or replace FUNCTION public.migrate_intake(p_secret text, p_name text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_form_key text DEFAULT NULL::text, p_status text DEFAULT 'new'::text, p_applied_at timestamp with time zone DEFAULT now(), p_interview_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_note text DEFAULT NULL::text, p_answers jsonb DEFAULT '{}'::jsonb, p_row_key text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_answers jsonb;
begin
  if not checklist_intake_secret_ok(p_secret) then
    raise exception '認証エラー';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception '氏名がありません'; end if;
  if p_status not in ('new','contacted','interview_set','interviewed','hired','rejected','declined') then
    raise exception '不正なステータス';
  end if;
  if p_row_key is not null and exists(select 1 from applicants where answers->>'_row' = p_row_key) then
    return null;
  end if;
  v_answers := coalesce(p_answers,'{}'::jsonb)
    || case when p_row_key is not null then jsonb_build_object('_row', p_row_key) else '{}'::jsonb end;
  select id into v_id from applicants
   where replace(replace(name,' ',''),'　','') = replace(replace(trim(p_name),' ',''),'　','')
     and user_id is null
   order by applied_at desc limit 1;
  if v_id is not null then
    update applicants set
      answers = v_answers || answers,
      phone = coalesce(phone, nullif(trim(coalesce(p_phone,'')),'')),
      email = coalesce(email, nullif(trim(coalesce(p_email,'')),'')),
      form_key = coalesce(form_key, p_form_key),
      interview_at = coalesce(interview_at, p_interview_at),
      note = coalesce(note, p_note),
      status = case when status='new' and p_status<>'new' then p_status else status end,
      status_changed_at = case when status='new' and p_status<>'new' then now() else status_changed_at end,
      updated_at = now()
     where id = v_id;
    return v_id;
  end if;
  v_id := gen_random_uuid();
  insert into applicants (id, name, phone, email, form_key, source, status, applied_at, status_changed_at, interview_at, note, answers)
  values (v_id, trim(p_name), nullif(trim(coalesce(p_phone,'')),''), nullif(trim(coalesce(p_email,'')),''),
          p_form_key, 'csv', p_status, coalesce(p_applied_at, now()), now(), p_interview_at, p_note, v_answers);
  return v_id;
end $function$


create or replace FUNCTION public.indeed_message_intake(p_secret text, p_body text, p_mail_id text, p_from text DEFAULT NULL::text, p_subject text DEFAULT NULL::text, p_sent_at timestamp with time zone DEFAULT now())
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text; v_dir text; v_aid uuid; v_name text; v_akey text;
        v_id uuid := gen_random_uuid(); v_exist uuid;
begin
  if not checklist_intake_secret_ok(p_secret) then
    raise exception '認証エラー';
  end if;
  if p_body is null or length(btrim(p_body)) = 0 then return null; end if;

  v_key := indeed_key(substring(coalesce(p_from,'') from '[A-Za-z0-9._%+-]+@indeedemail\.com'));

  -- ① 応募者ごとの返信用アドレスと一致 → その応募者からの受信（一番確実）
  if v_key is not null then
    select id into v_aid from applicants
     where indeed_key(answers->>'Indeed連絡先') = v_key
     order by applied_at desc limit 1;
    if v_aid is not null then v_dir := 'in'; end if;
  end if;

  -- ② 見つからなければ件名の氏名で応募者を探す
  if v_aid is null and p_subject is not null then
    v_name := substring(p_subject from '-\s*(.+?)さんから応募がありました');
    if v_name is not null then
      select id, indeed_key(answers->>'Indeed連絡先') into v_aid, v_akey
        from applicants
       where replace(replace(name,' ',''),'　','') = replace(replace(btrim(v_name),' ',''),'　','')
       order by applied_at desc limit 1;
    end if;
  end if;
  if v_aid is null then return null; end if; -- 誰の話か判らないので取り込まない

  -- 送り手の判定
  if v_dir is null then
    if v_key is null then
      -- Indeedの中継アドレスが取れない＝自社から直接出したメール
      v_dir := case when coalesce(p_from,'') ilike '%ns0314.com%' then 'out' else 'in' end;
    elsif exists(select 1 from indeed_own_keys where key = v_key) then
      v_dir := 'out'; -- 「こちら側」と判っているアドレス
    elsif v_akey is not null and v_akey <> v_key then
      -- 応募者本人の中継アドレスは判っていて、それとは別 → こちら側。以後のために覚える
      v_dir := 'out';
      insert into indeed_own_keys(key, note) values (v_key, '自動判定') on conflict (key) do nothing;
    else
      v_dir := 'in'; -- 判らないときは「応募者から」。違っていれば画面で1回直せば全部直る
    end if;
  end if;

  -- すでに取り込み済みなら、送り手だけ入れ直す（手で直した分はそのまま）
  select id into v_exist from applicant_messages where source_ref = p_mail_id;
  if v_exist is not null then
    update applicant_messages
       set sender_key = coalesce(v_key, sender_key),
           direction = case when direction_fixed then direction else v_dir end
     where id = v_exist;
    return v_exist;
  end if;

  insert into applicant_messages (id, applicant_id, channel, direction, body, sent_at, source_ref, sender_key)
  values (v_id, v_aid, 'indeed', v_dir, left(btrim(p_body), 8000),
          coalesce(p_sent_at, now()), p_mail_id, v_key);

  if v_dir = 'in' then
    update applicants set msg_received_at = coalesce(p_sent_at, now()), msg_seen_at = null,
                          updated_at = now()
     where id = v_aid;
    insert into notifications (recipient_id, type, body_i18n, link)
    select u.id, 'applicant_message', -- v2.6.65 「応募が入った」と別種類にした（従来は applicant_new）
           jsonb_build_object('ja', 'Indeedにメッセージが届きました: '
             || (select name from applicants where id = v_aid) || 'さん'),
           jsonb_build_object('applicant_id', v_aid)
      from users u where u.is_active and can_see_applicant(u.id, (select store_id from applicants where id = v_aid));
  end if;
  return v_id;
end $function$


create or replace FUNCTION public.notify_route_send(p_kind text, p_target text, p_text text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare v_token text;
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/smaregi-sync';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  c_key  constant text := (select value from app_secrets where key = 'checklist_intake_secret');
begin
  if p_target is null or length(trim(p_target)) = 0 then return; end if;
  begin
    if p_kind = 'chatwork' then
      select value into v_token from app_secrets where key = 'chatwork_token';
      if v_token is null or length(trim(v_token)) = 0 then
        insert into lark_log(ok, message, detail) values (false, left(p_text,300), 'Chatworkのトークン未設定');
        return;
      end if;
      -- Edge Function に中継（実際の送信結果は Edge Function 側が lark_log に記録する）
      perform net.http_post(
        url := c_fn,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'apikey', c_anon,
          'Authorization', 'Bearer ' || c_anon),
        body := jsonb_build_object(
          'action', 'notify_chatwork',
          'secret', c_key,
          'room', trim(p_target),
          'text', p_text,
          'token', trim(v_token))
      );
    else
      perform net.http_post(
        url := trim(p_target),
        headers := '{"Content-Type":"application/json"}'::jsonb,
        body := jsonb_build_object('msg_type','text','content',jsonb_build_object('text',p_text))
      );
      insert into lark_log(ok, message, detail) values (true, left(p_text,300), 'Lark');
    end if;
  exception when others then
    insert into lark_log(ok, message, detail) values (false, left(p_text,300), SQLERRM);
  end;
end $function$


create or replace FUNCTION public.indeed_fill_url(p_secret text, p_url text, p_mail_id text DEFAULT NULL::text, p_name text DEFAULT NULL::text, p_applied_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n int := 0;
begin
  if not checklist_intake_secret_ok(p_secret) then
    raise exception '認証エラー';
  end if;
  if p_url is null or length(trim(p_url)) = 0 then return 0; end if;

  -- まずは取り込み元のメールIDで一致する応募者を探す（一番確実）
  if p_mail_id is not null then
    update applicants set indeed_url = trim(p_url), updated_at = now()
     where source_ref = p_mail_id and indeed_url is null;
    get diagnostics v_n = row_count;
    if v_n > 0 then return v_n; end if;
  end if;

  -- 見つからなければ「同じ氏名・応募日が前後3日以内」のIndeed応募に入れる
  if p_name is not null and p_applied_at is not null then
    update applicants set indeed_url = trim(p_url), updated_at = now()
     where source = 'indeed' and indeed_url is null
       and replace(replace(name,' ',''),'　','') = replace(replace(trim(p_name),' ',''),'　','')
       and applied_at between p_applied_at - interval '3 days' and p_applied_at + interval '3 days';
    get diagnostics v_n = row_count;
  end if;
  return v_n;
end $function$


create or replace FUNCTION public.indeed_intake(p_secret text, p_name text, p_job text DEFAULT NULL::text, p_location text DEFAULT NULL::text, p_store text DEFAULT NULL::text, p_contact text DEFAULT NULL::text, p_mail_id text DEFAULT NULL::text, p_applied_at timestamp with time zone DEFAULT now(), p_url text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_tkey text; v_form_key text; v_store_id uuid; v_ans jsonb;
begin
  if not checklist_intake_secret_ok(p_secret) then
    raise exception '認証エラー';
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
end $function$


create or replace FUNCTION public.form_intake(p_secret text, p_name text, p_phone text DEFAULT NULL::text, p_form_key text DEFAULT NULL::text, p_answers jsonb DEFAULT '{}'::jsonb, p_submitted_at timestamp with time zone DEFAULT now(), p_row_key text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_answers jsonb;
begin
  if not checklist_intake_secret_ok(p_secret) then
    raise exception '認証エラー';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception '氏名がありません'; end if;
  if p_row_key is not null and exists(
       select 1 from applicants where answers->>'_row' = p_row_key) then
    return null;   -- 同じ行はもう取り込み済み
  end if;
  v_answers := coalesce(p_answers,'{}'::jsonb)
    || case when p_row_key is not null then jsonb_build_object('_row', p_row_key) else '{}'::jsonb end;

  v_id := applicant_match(p_name, p_phone, null);   -- v2.6.30 電話でも照合する
  if v_id is not null then
    update applicants set
      answers = answers || v_answers,
      form_key = coalesce(form_key, p_form_key),
      phone = coalesce(phone, nullif(trim(coalesce(p_phone,'')),'')),
      form_received_at = coalesce(p_submitted_at, now()),
      form_seen_at = null,
      updated_at = now()
     where id = v_id;
    insert into notifications (recipient_id, type, body_i18n, link)
    select u.id, 'applicant_new',
           jsonb_build_object('ja', 'フォーム回答が届きました: ' || trim(p_name) || 'さん'),
           jsonb_build_object('applicant_id', v_id)
      from users u where u.is_active and can_see_applicant(u.id, (select store_id from applicants where id = v_id));
    return v_id;
  end if;

  v_id := gen_random_uuid();
  insert into applicants (id, name, phone, form_key, source, answers, applied_at, form_received_at)
  values (v_id, trim(p_name), nullif(trim(coalesce(p_phone,'')),''), p_form_key, 'form',
          v_answers, coalesce(p_submitted_at, now()), coalesce(p_submitted_at, now()));
  insert into notifications (recipient_id, type, body_i18n, link)
  select u.id, 'applicant_new',
         jsonb_build_object('ja', '新しいフォーム応募: ' || trim(p_name) || 'さん'),
         jsonb_build_object('applicant_id', v_id)
    from users u where u.is_active and can_see_applicant(u.id, (select store_id from applicants where id = v_id));
  return v_id;
end $function$

