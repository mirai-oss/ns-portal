-- 2026-09-01 担当B（nippo）
-- ユーザー指摘: 「応募者の中のLINE連携」と「入社完了後のLINE連携」が別々になっている。
-- ①応募者としてLINE連携済みの人が入社したら、そのLINE連携を従業員側(users)にも引き継ぐ
-- ②応募者経由でない人（スマレジに既存＋管理システムだけ新規登録する人）は、登録時に
--   その場でLINE連携できるようにする（nippo側UIで対応）
-- ③どちらの経路でLINEが連携されても、「入社登録が完了しました」の案内が届くようにする

-- 従業員版「入社案内を送った」フラグ（applicants.join_msg_sent_atの従業員版）
alter table employee_profiles add column if not exists join_welcome_sent_at timestamptz;
comment on column employee_profiles.join_welcome_sent_at is '入社登録完了のLINE案内を送った時刻。応募者経由でない人（line_intake_userでの事後連携）向け。二重送信防止用';

-- ---- ①register_via_invite: 応募者のLINE連携を従業員(users)へ引き継ぐ ----
-- 既存の関数定義を丸ごと再作成（1箇所だけ追記。他は無変更）
create or replace function public.register_via_invite(p_token text, p_email text, p_password text, p_name text, p_name_kana text DEFAULT NULL::text, p_birth_date date DEFAULT NULL::date, p_phone text DEFAULT NULL::text, p_postal_code text DEFAULT NULL::text, p_address text DEFAULT NULL::text, p_emergency_name text DEFAULT NULL::text, p_emergency_relation text DEFAULT NULL::text, p_emergency_phone text DEFAULT NULL::text, p_hire_date date DEFAULT NULL::date, p_extra jsonb DEFAULT NULL::jsonb, p_smaregi_staff_id text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'auth'
AS $function$
declare
  v invitations%rowtype;
  v_id uuid := gen_random_uuid();
  v_store_names text;
  v_sm text;
begin
  select * into v from invitations
   where token = p_token and used_at is null and expires_at > now()
   for update;
  if not found then
    raise exception '招待リンクが無効か期限切れです。本部までお問い合わせください';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception '氏名を入力してください';
  end if;
  if p_password is null or length(p_password) < 8 then
    raise exception 'パスワードは8文字以上にしてください';
  end if;
  if p_email is null or position('@' in p_email) = 0 then
    raise exception 'メールアドレスが正しくありません';
  end if;
  if exists (select 1 from auth.users where email = lower(p_email)) then
    raise exception 'このメールアドレスは既に登録されています';
  end if;

  v_sm := coalesce(v.smaregi_staff_id, nullif(trim(coalesce(p_smaregi_staff_id, '')), ''));
  if v_sm is not null and exists (select 1 from employee_profiles where smaregi_staff_id = v_sm) then
    raise exception '選択したスマレジスタッフは既に別のアカウントと連携されています。本部までお問い合わせください';
  end if;

  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change
  ) values (
    '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
    lower(p_email), extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(), '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object('name', p_name, 'role', v.role),
    now(), now(), '', '', '', ''
  );
  insert into auth.identities (
    id, user_id, provider_id, identity_data, provider,
    last_sign_in_at, created_at, updated_at
  ) values (
    gen_random_uuid(), v_id, v_id::text,
    jsonb_build_object('sub', v_id::text, 'email', lower(p_email), 'email_verified', true),
    'email', now(), now(), now()
  );
  -- ↑ on_auth_user_created トリガーが public.users を作成する

  update users set team_id = v.team_id where id = v_id and v.team_id is not null;

  -- 2026-09-01追加: 応募者としてLINE連携済みなら、そのまま従業員側にも引き継ぐ
  -- （今後シフト送信等でLINE連携が必須になるため、再連携の手間を無くす。ユーザー要望）
  if v.applicant_id is not null then
    update users u set line_user_id = ap.line_user_id, line_linked_at = ap.line_linked_at, updated_at = now()
      from applicants ap
      where ap.id = v.applicant_id and ap.line_user_id is not null and u.id = v_id;
  end if;

  insert into user_stores (user_id, store_id, is_primary)
  select v_id, s.sid, s.rn = 1
    from (select unnest(v.store_ids) sid, generate_subscripts(v.store_ids, 1) rn) s;

  insert into employee_profiles (
    user_id, name_kana, birth_date, phone, postal_code, address,
    emergency_name, emergency_relation, emergency_phone, hire_date, extra,
    smaregi_staff_id, smaregi_sync_status
  ) values (
    v_id, p_name_kana, p_birth_date, p_phone, p_postal_code, p_address,
    p_emergency_name, p_emergency_relation, p_emergency_phone,
    coalesce(p_hire_date, current_date), p_extra,
    v_sm, case when v_sm is not null then 'synced' else 'pending' end
  );

  update invitations set used_at = now(), used_by = v_id where id = v.id;

  select coalesce(string_agg(s.name, '・' order by s.sort_order), '所属なし')
    into v_store_names from stores s where s.id = any(v.store_ids);
  insert into notifications (recipient_id, actor_id, type, body_i18n, link)
  select u.id, v_id, 'join_registered',
         jsonb_build_object('ja', p_name || 'さんが入社登録を完了しました（' ||
           case v.role when 'AL' then 'アルバイト' when 'SHAIN' then '社員'
                       when 'TENCHO' then '店長' when 'TEAM' then 'チーム'
                       when 'HQ' then '本部' when 'CEO' then '社長' else v.role end
           || '・' || v_store_names || '）'),
         jsonb_build_object('page', 'admin', 'user_id', v_id)
    from users u where u.role in ('CEO','HQ') and u.is_active;

  return v_id;
end $function$;

-- ---- ③line_intake_user: LINE連携が完了した瞬間に「入社案内」も送れるようにwelcome_textを返す ----
create or replace function public.line_intake_user(p_secret text, p_line_user_id text, p_text text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_uid uuid; v_uname text; v_code text; v_welcome text; v_hire_date date; v_stores text;
begin
  if not checklist_intake_secret_ok(p_secret) then
    raise exception '認証エラー';
  end if;
  if p_line_user_id is null or length(btrim(p_line_user_id)) = 0 then
    return jsonb_build_object('ok', false);
  end if;

  select id into v_uid from users where line_user_id = p_line_user_id and is_active limit 1;
  if v_uid is not null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  v_code := (regexp_match(upper(coalesce(p_text,'')), '[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{6}'))[1];
  if v_code is null then
    return jsonb_build_object('ok', false);
  end if;

  select id, name into v_uid, v_uname from users
   where line_code = v_code and line_user_id is null and is_active limit 1;
  if v_uid is null then
    return jsonb_build_object('ok', false);
  end if;

  update users set line_user_id = p_line_user_id, line_linked_at = now(), updated_at = now()
   where id = v_uid;

  -- 2026-09-01追加: 応募者経由でない入社登録（スマレジ既存→管理システムだけ新規登録）は
  -- register_via_invite時点でLINEが未連携のため入社案内が送れていない。ここで初めてLINEが
  -- 連携できた瞬間に、まだ送っていなければ入社案内もあわせて送る（二重送信はjoin_welcome_sent_atで防止）
  select ep.hire_date into v_hire_date from employee_profiles ep
    where ep.user_id = v_uid and ep.join_welcome_sent_at is null;
  if v_hire_date is not null then
    select coalesce(string_agg(s.name, '・' order by s.sort_order), '所属なし')
      into v_stores from stores s join user_stores us on us.store_id = s.id where us.user_id = v_uid;
    v_welcome := '🐔 ' || v_uname || E'さん\n\n入社登録が完了しました！\n所属店舗: ' || v_stores ||
      E'\n\nこれからよろしくお願いいたします。シフト提出の締切が近いときなどにこちらへお知らせします。' ||
      E'\n\nhttps://mirai-oss.github.io/nippo/';
    update employee_profiles set join_welcome_sent_at = now() where user_id = v_uid;
  end if;

  return jsonb_build_object('ok', true, 'linked', true, 'name', v_uname,
    'reply', v_uname || 'さん、LINE連携が完了しました。シフト提出の締切が近いときにこちらへお知らせします。',
    'welcome_text', v_welcome);
end $function$;
