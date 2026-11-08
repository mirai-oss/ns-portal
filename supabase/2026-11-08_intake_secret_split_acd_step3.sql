-- =====================================================================
-- P0-1 共有シークレット分離（A・C・D）手順3: 受信側DB関数を新Secret対応にする【移行期間版】
-- =====================================================================
-- C 採用取込（GAS → RPC 4本）      : recruit_intake_secret_ok()  … Vault 'recruit_intake_secret'
-- D 現場チェック期限切れ点検（GAS → RPC 1本）: checklist_alert_secret_ok() … Vault 'checklist_alert_secret'
-- ・合言葉は専用ヘッダ X-Intake-Secret で受ける（p_secret 引数も互換のため受け付ける）
-- ・不一致は HTTP 403（raise sqlstate 'PT403'）。判定は各関数の先頭で行い、判定前に書き込み・通知はしない
-- ・この版は「新Secret または 従来の合言葉（checklist_intake_secret_ok）」の両対応。
--   手順8（…_step8_final.sql）で従来側を外し、app_secrets の前の値も削除する
-- ・関数本体は 2026-08-21_intake_secret_rotation(_part2).sql の定義そのまま（判定部分だけ差し替え）
-- 前提: 手順2で Vault に 2つの Secret を登録済み
-- 実行場所: Supabase SQL Editor（このファイルに値は含まれない・何度実行しても壊れない）
-- =====================================================================

begin;

-- C 採用取込用: 専用ヘッダ X-Intake-Secret（PostgREST の request.headers 経由）または p_secret 引数の値を、
-- Vault の 'recruit_intake_secret' と比べる。値はこのファイルにもDBの通常テーブルにも置かない。
create or replace function public.recruit_intake_secret_ok(p_secret text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_hdr text; v_given text; v_val text;
begin
  begin
    v_hdr := nullif(btrim(coalesce(current_setting('request.headers', true), '')), '');
    if v_hdr is not null then v_given := (v_hdr::json ->> 'x-intake-secret'); end if;
  exception when others then v_given := null;
  end;
  v_given := coalesce(nullif(btrim(coalesce(v_given, '')), ''), nullif(btrim(coalesce(p_secret, '')), ''));
  if v_given is null then return false; end if;
  select decrypted_secret into v_val from vault.decrypted_secrets where name = 'recruit_intake_secret' limit 1;
  return v_val is not null and length(v_val) >= 24 and v_given = v_val;
end $$;
revoke all on function public.recruit_intake_secret_ok(text) from public, anon, authenticated;
grant execute on function public.recruit_intake_secret_ok(text) to service_role;

-- D 期限切れ点検用: 専用ヘッダ X-Intake-Secret（PostgREST の request.headers 経由）または p_secret 引数の値を、
-- Vault の 'checklist_alert_secret' と比べる。値はこのファイルにもDBの通常テーブルにも置かない。
create or replace function public.checklist_alert_secret_ok(p_secret text default null)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_hdr text; v_given text; v_val text;
begin
  begin
    v_hdr := nullif(btrim(coalesce(current_setting('request.headers', true), '')), '');
    if v_hdr is not null then v_given := (v_hdr::json ->> 'x-intake-secret'); end if;
  exception when others then v_given := null;
  end;
  v_given := coalesce(nullif(btrim(coalesce(v_given, '')), ''), nullif(btrim(coalesce(p_secret, '')), ''));
  if v_given is null then return false; end if;
  select decrypted_secret into v_val from vault.decrypted_secrets where name = 'checklist_alert_secret' limit 1;
  return v_val is not null and length(v_val) >= 24 and v_given = v_val;
end $$;
revoke all on function public.checklist_alert_secret_ok(text) from public, anon, authenticated;
grant execute on function public.checklist_alert_secret_ok(text) to service_role;

-- ---- C: indeed_intake（本体は part2 と同じ・判定だけ新Secret or 従来）----
create or replace FUNCTION public.indeed_intake(p_secret text, p_name text, p_job text DEFAULT NULL::text, p_location text DEFAULT NULL::text, p_store text DEFAULT NULL::text, p_contact text DEFAULT NULL::text, p_mail_id text DEFAULT NULL::text, p_applied_at timestamp with time zone DEFAULT now(), p_url text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_tkey text; v_form_key text; v_store_id uuid; v_ans jsonb;
begin
  if not (public.recruit_intake_secret_ok(p_secret) or public.checklist_intake_secret_ok(p_secret)) then
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

-- ---- C: indeed_message_intake（本体は part2 と同じ・判定だけ新Secret or 従来）----
create or replace FUNCTION public.indeed_message_intake(p_secret text, p_body text, p_mail_id text, p_from text DEFAULT NULL::text, p_subject text DEFAULT NULL::text, p_sent_at timestamp with time zone DEFAULT now())
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_key text; v_dir text; v_aid uuid; v_name text; v_akey text;
        v_id uuid := gen_random_uuid(); v_exist uuid;
begin
  if not (public.recruit_intake_secret_ok(p_secret) or public.checklist_intake_secret_ok(p_secret)) then
    raise sqlstate 'PT403' using message = '認証エラー';
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
end $function$;

-- ---- C: form_intake（本体は part2 と同じ・判定だけ新Secret or 従来）----
create or replace FUNCTION public.form_intake(p_secret text, p_name text, p_phone text DEFAULT NULL::text, p_form_key text DEFAULT NULL::text, p_answers jsonb DEFAULT '{}'::jsonb, p_submitted_at timestamp with time zone DEFAULT now(), p_row_key text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_answers jsonb;
begin
  if not (public.recruit_intake_secret_ok(p_secret) or public.checklist_intake_secret_ok(p_secret)) then
    raise sqlstate 'PT403' using message = '認証エラー';
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
end $function$;

-- ---- C: indeed_fill_url（本体は part2 と同じ・判定だけ新Secret or 従来）----
create or replace FUNCTION public.indeed_fill_url(p_secret text, p_url text, p_mail_id text DEFAULT NULL::text, p_name text DEFAULT NULL::text, p_applied_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n int := 0;
begin
  if not (public.recruit_intake_secret_ok(p_secret) or public.checklist_intake_secret_ok(p_secret)) then
    raise sqlstate 'PT403' using message = '認証エラー';
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
end $function$;

-- ---- D: checklist_overdue_check（本体は 2026-08-21 と同じ・判定は新Secretのみ。旧値は受け付けない）----
create or replace function checklist_overdue_check(p_secret text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_alerted int := 0; r record; v_body text;
begin
  if not public.checklist_alert_secret_ok(p_secret) then  -- D は移行期間なし（旧値の再受付を避ける・2026-11-08 封鎖中のため）
    raise sqlstate 'PT403' using message = '認証エラー';
  end if;

  for r in
    select i.id as item_id, i.label, i.due_time, s.id as store_id, s.name as store_name
      from checklist_items i
      join checklist_templates t on t.id = i.template_id and t.is_active
      join stores s on s.is_active and (t.store_id is null or t.store_id = s.id)
     where i.is_active
       and i.due_time is not null
       and (now() at time zone 'Asia/Tokyo')::time > i.due_time
       and not exists (
         select 1 from checklist_checks c
          where c.item_id = i.id and c.store_id = s.id and c.work_date = biz_date()
       )
       and not exists (
         select 1 from checklist_overdue_alerts a
          where a.item_id = i.id and a.store_id = s.id and a.work_date = biz_date()
       )
  loop
    insert into checklist_overdue_alerts (item_id, store_id, work_date)
    values (r.item_id, r.store_id, biz_date())
    on conflict (item_id, store_id, work_date) do nothing;

    v_body := '⏰ 期限切れ未完了: ' || r.store_name || '「' || r.label || '」（期限 '
      || to_char(r.due_time, 'HH24:MI') || '）がまだチェックされていません';

    insert into notifications (recipient_id, type, body_i18n, link)
    select distinct u.id, 'checklist_overdue',
           jsonb_build_object('ja', v_body),
           jsonb_build_object('item_id', r.item_id, 'store_id', r.store_id, 'work_date', biz_date()::text)
      from users u
     where u.is_active
       and (
         u.role in ('CEO','HQ')
         or (u.role = 'TEAM' and exists(select 1 from team_stores ts where ts.team_id = u.team_id and ts.store_id = r.store_id))
         or (u.role = 'TENCHO' and exists(select 1 from user_stores us where us.user_id = u.id and us.store_id = r.store_id))
       );
    v_alerted := v_alerted + 1;
  end loop;

  return jsonb_build_object('ok', true, 'alerted', v_alerted);
end $$;

-- D の実行権限（2026-11-08 緊急封鎖からの正規復旧・必要最小限）: PUBLIC 不可／anon 可（新Secret判定必須）／authenticated 不可／service_role 可
revoke execute on function public.checklist_overdue_check(text) from public, authenticated;
grant execute on function public.checklist_overdue_check(text) to anon, service_role;

commit;

select 'P0-1 手順3 完了: C/D 受信側を新Secret対応（移行期間版）' as result;
