-- ============================================================
-- 社内情報管理システム: 関数とRLSポリシーを info スキーマへ
-- 生成: 4_gen_policies.py
-- ※ handle_new_user は意図的に移植しない（下記コメント参照）
-- ============================================================

-- ---------- 関数 ----------
CREATE OR REPLACE FUNCTION info.archive_secret()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'info', 'public'
AS $function$
begin
  if old.secret is distinct from new.secret then
    insert into credential_secret_history (credential_id, secret, replaced_by)
    values (old.credential_id, old.secret, auth.uid());
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION info.can_access_corp(corp uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'info', 'public'
AS $function$
  select coalesce((
    select case
      when p.is_master then true
      when exists (select 1 from user_corporations uc where uc.user_id = p.id)
        then exists (select 1 from user_corporations uc where uc.user_id = p.id and uc.corporation_id = corp)
      when exists (select 1 from role_corporations rc where rc.role_id = p.role_id)
        then exists (select 1 from role_corporations rc where rc.role_id = p.role_id and rc.corporation_id = corp)
      else true
    end
    from profiles p where p.id = auth.uid() and p.is_active
  ), false);
$function$;

CREATE OR REPLACE FUNCTION info.export_credentials(corp uuid)
 RETURNS TABLE(service_name text, category text, store_names text, username text, secret text, login_url text, media_contact_name text, media_contact_phone text, memo text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'info', 'public'
AS $function$
declare
  v_ok boolean;
begin
  select (p.is_master or exists (
    select 1 from role_permissions rp
    where rp.role_id = p.role_id
      and rp.category_id = 'id_pw'
      and rp.permission = 'edit'
  )) into v_ok
  from profiles p
  where p.id = auth.uid() and p.is_active;

  if v_ok is distinct from true then
    raise exception 'permission denied';
  end if;

  insert into audit_logs (user_id, action, target)
  values (auth.uid(), 'export_csv', 'credentials');

  return query
    select
      c.service_name,
      c.category,
      coalesce((
        select string_agg(s.name, '・')
        from credential_stores cs
        join stores s on s.id = cs.store_id
        where cs.credential_id = c.id
      ), '法人全体'),
      c.username,
      coalesce(sec.secret, ''),
      c.login_url,
      c.media_contact_name,
      c.media_contact_phone,
      c.memo
    from credentials c
    left join credential_secrets sec on sec.credential_id = c.id
    where c.corporation_id = corp
    order by c.service_name;
end $function$;

-- [移植しない] handle_new_user: 新規認証ユーザーに自動で社内情報の権限を与える処理。
--   ハブでは日報の全従業員が新規ユーザーになるため、自動付与は危険。
--   社内情報を使う人は info.profiles に明示的に行を追加すること。

CREATE OR REPLACE FUNCTION info.has_perm(cat text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'info', 'public'
AS $function$
  select coalesce((
    select case
      when p.is_master then true
      when exists (select 1 from user_permissions up where up.user_id = p.id and up.category_id = cat)
        then (select up.permission <> 'none' from user_permissions up where up.user_id = p.id and up.category_id = cat)
      else exists (select 1 from role_permissions rp where rp.role_id = p.role_id and rp.category_id = cat and rp.permission <> 'none')
    end
    from profiles p where p.id = auth.uid() and p.is_active
  ), false);
$function$;

CREATE OR REPLACE FUNCTION info.is_master()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'info', 'public'
AS $function$
  select coalesce(
    (select p.is_master from profiles p where p.id = auth.uid() and p.is_active),
    false
  );
$function$;

CREATE OR REPLACE FUNCTION info.reveal_secret(cred_id uuid, mode text DEFAULT 'reveal'::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'info', 'public'
AS $function$
declare
  v_ok boolean;
  v_secret text;
  v_service text;
begin
  select (p.is_master or exists (
    select 1 from role_permissions rp
    where rp.role_id = p.role_id
      and rp.category_id = 'id_pw'
      and rp.permission <> 'none'
  )) into v_ok
  from profiles p
  where p.id = auth.uid() and p.is_active;

  if v_ok is distinct from true then
    raise exception 'permission denied';
  end if;

  select c.service_name into v_service from credentials c where c.id = cred_id;
  select s.secret into v_secret from credential_secrets s where s.credential_id = cred_id;

  insert into audit_logs (user_id, action, target)
  values (auth.uid(), case when mode = 'copy' then 'copy_secret' else 'reveal_secret' end, v_service);

  return v_secret;
end $function$;

CREATE OR REPLACE FUNCTION info.reveal_secret_history(cred_id uuid)
 RETURNS TABLE(replaced_at timestamp with time zone, replaced_by_name text, secret text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'info', 'public'
AS $function$
begin
  if not is_master() then
    raise exception 'permission denied';
  end if;

  insert into audit_logs (user_id, action, target)
  values (auth.uid(), 'reveal_secret_history',
    (select c.service_name from credentials c where c.id = cred_id));

  return query
    select h.replaced_at, coalesce(p.name, '不明'), h.secret
    from credential_secret_history h
    left join profiles p on p.id = h.replaced_by
    where h.credential_id = cred_id
    order by h.replaced_at desc
    limit 20;
end $function$;

-- ---------- 行レベルセキュリティを有効化 ----------
alter table info."audit_logs" enable row level security;
alter table info."bank_accounts" enable row level security;
alter table info."brands" enable row level security;
alter table info."categories" enable row level security;
alter table info."corporations" enable row level security;
alter table info."credential_secret_history" enable row level security;
alter table info."credential_secrets" enable row level security;
alter table info."credential_stores" enable row level security;
alter table info."credentials" enable row level security;
alter table info."deadlines" enable row level security;
alter table info."documents" enable row level security;
alter table info."employee_salaries" enable row level security;
alter table info."employees" enable row level security;
alter table info."loans" enable row level security;
alter table info."photos" enable row level security;
alter table info."profiles" enable row level security;
alter table info."properties" enable row level security;
alter table info."real_estate_properties" enable row level security;
alter table info."real_estate_units" enable row level security;
alter table info."role_corporations" enable row level security;
alter table info."role_permissions" enable row level security;
alter table info."roles" enable row level security;
alter table info."stores" enable row level security;
alter table info."suppliers" enable row level security;
alter table info."user_corporations" enable row level security;
alter table info."user_permissions" enable row level security;
alter table info."user_stores" enable row level security;
alter table info."utilities" enable row level security;

-- ---------- ポリシー ----------
drop policy if exists "master_all" on info."audit_logs";
create policy "master_all" on info."audit_logs"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "master_all" on info."bank_accounts";
create policy "master_all" on info."bank_accounts"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_bank_accounts" on info."bank_accounts";
create policy "read_bank_accounts" on info."bank_accounts"
  as permissive
  for select
  to public
  using ((info.has_perm('bank'::text) AND info.can_access_corp(corporation_id)));

drop policy if exists "master_all" on info."brands";
create policy "master_all" on info."brands"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_basics" on info."brands";
create policy "read_basics" on info."brands"
  as permissive
  for select
  to public
  using (info.can_access_corp(corporation_id));

drop policy if exists "master_all" on info."categories";
create policy "master_all" on info."categories"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_basics" on info."categories";
create policy "read_basics" on info."categories"
  as permissive
  for select
  to public
  using ((auth.uid() IS NOT NULL));

drop policy if exists "master_all" on info."corporations";
create policy "master_all" on info."corporations"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_basics" on info."corporations";
create policy "read_basics" on info."corporations"
  as permissive
  for select
  to public
  using (info.can_access_corp(id));

drop policy if exists "master_all" on info."credential_secrets";
create policy "master_all" on info."credential_secrets"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "master_all" on info."credential_stores";
create policy "master_all" on info."credential_stores"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_credential_stores" on info."credential_stores";
create policy "read_credential_stores" on info."credential_stores"
  as permissive
  for select
  to public
  using ((auth.uid() IS NOT NULL));

drop policy if exists "master_all" on info."credentials";
create policy "master_all" on info."credentials"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_credentials" on info."credentials";
create policy "read_credentials" on info."credentials"
  as permissive
  for select
  to public
  using ((info.has_perm('id_pw'::text) AND info.can_access_corp(corporation_id)));

drop policy if exists "master_all" on info."deadlines";
create policy "master_all" on info."deadlines"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_deadlines" on info."deadlines";
create policy "read_deadlines" on info."deadlines"
  as permissive
  for select
  to public
  using (info.can_access_corp(corporation_id));

drop policy if exists "insert_documents" on info."documents";
create policy "insert_documents" on info."documents"
  as permissive
  for insert
  to public
  with check ((auth.uid() IS NOT NULL));

drop policy if exists "master_all" on info."documents";
create policy "master_all" on info."documents"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_documents" on info."documents";
create policy "read_documents" on info."documents"
  as permissive
  for select
  to public
  using (info.can_access_corp(corporation_id));

drop policy if exists "master_all" on info."employee_salaries";
create policy "master_all" on info."employee_salaries"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_salaries" on info."employee_salaries";
create policy "read_salaries" on info."employee_salaries"
  as permissive
  for select
  to public
  using (info.has_perm('salary'::text));

drop policy if exists "master_all" on info."employees";
create policy "master_all" on info."employees"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_employees" on info."employees";
create policy "read_employees" on info."employees"
  as permissive
  for select
  to public
  using ((info.has_perm('employee'::text) AND info.can_access_corp(corporation_id)));

drop policy if exists "master_all" on info."loans";
create policy "master_all" on info."loans"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_loans" on info."loans";
create policy "read_loans" on info."loans"
  as permissive
  for select
  to public
  using ((info.has_perm('loan'::text) AND info.can_access_corp(corporation_id)));

drop policy if exists "insert_photos" on info."photos";
create policy "insert_photos" on info."photos"
  as permissive
  for insert
  to public
  with check ((auth.uid() IS NOT NULL));

drop policy if exists "master_all" on info."photos";
create policy "master_all" on info."photos"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_photos" on info."photos";
create policy "read_photos" on info."photos"
  as permissive
  for select
  to public
  using (info.can_access_corp(corporation_id));

drop policy if exists "master_all" on info."profiles";
create policy "master_all" on info."profiles"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_own_profile" on info."profiles";
create policy "read_own_profile" on info."profiles"
  as permissive
  for select
  to public
  using ((id = auth.uid()));

drop policy if exists "master_all" on info."properties";
create policy "master_all" on info."properties"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_properties" on info."properties";
create policy "read_properties" on info."properties"
  as permissive
  for select
  to public
  using ((info.has_perm('property'::text) AND info.can_access_corp(corporation_id)));

drop policy if exists "master_all" on info."real_estate_properties";
create policy "master_all" on info."real_estate_properties"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_re" on info."real_estate_properties";
create policy "read_re" on info."real_estate_properties"
  as permissive
  for select
  to public
  using ((info.has_perm('real_estate'::text) AND info.can_access_corp(corporation_id)));

drop policy if exists "master_all" on info."real_estate_units";
create policy "master_all" on info."real_estate_units"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_reu" on info."real_estate_units";
create policy "read_reu" on info."real_estate_units"
  as permissive
  for select
  to public
  using (info.has_perm('real_estate'::text));

drop policy if exists "master_all" on info."role_corporations";
create policy "master_all" on info."role_corporations"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_rc" on info."role_corporations";
create policy "read_rc" on info."role_corporations"
  as permissive
  for select
  to public
  using ((auth.uid() IS NOT NULL));

drop policy if exists "master_all" on info."role_permissions";
create policy "master_all" on info."role_permissions"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_own_permissions" on info."role_permissions";
create policy "read_own_permissions" on info."role_permissions"
  as permissive
  for select
  to public
  using ((role_id = ( SELECT profiles.role_id
   FROM info.profiles
  WHERE (profiles.id = auth.uid()))));

drop policy if exists "master_all" on info."roles";
create policy "master_all" on info."roles"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "master_all" on info."stores";
create policy "master_all" on info."stores"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_basics" on info."stores";
create policy "read_basics" on info."stores"
  as permissive
  for select
  to public
  using (info.can_access_corp(corporation_id));

drop policy if exists "master_all" on info."suppliers";
create policy "master_all" on info."suppliers"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_suppliers" on info."suppliers";
create policy "read_suppliers" on info."suppliers"
  as permissive
  for select
  to public
  using ((info.has_perm('supplier'::text) AND info.can_access_corp(corporation_id)));

drop policy if exists "master_all" on info."user_corporations";
create policy "master_all" on info."user_corporations"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_own_uc" on info."user_corporations";
create policy "read_own_uc" on info."user_corporations"
  as permissive
  for select
  to public
  using ((user_id = auth.uid()));

drop policy if exists "master_all" on info."user_permissions";
create policy "master_all" on info."user_permissions"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_own_up" on info."user_permissions";
create policy "read_own_up" on info."user_permissions"
  as permissive
  for select
  to public
  using ((user_id = auth.uid()));

drop policy if exists "master_all" on info."user_stores";
create policy "master_all" on info."user_stores"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_own_stores" on info."user_stores";
create policy "read_own_stores" on info."user_stores"
  as permissive
  for select
  to public
  using ((user_id = auth.uid()));

drop policy if exists "master_all" on info."utilities";
create policy "master_all" on info."utilities"
  as permissive
  for all
  to public
  using (info.is_master());

drop policy if exists "read_utilities" on info."utilities";
create policy "read_utilities" on info."utilities"
  as permissive
  for select
  to public
  using ((info.has_perm('utility'::text) AND info.can_access_corp(corporation_id)));

-- ---------- トリガー ----------
drop trigger if exists "on_secret_update" on info."credential_secrets";
CREATE TRIGGER on_secret_update BEFORE UPDATE ON info.credential_secrets FOR EACH ROW EXECUTE FUNCTION info.archive_secret();
-- [移植しない] on_auth_user_created on users（handle_new_user と同じ理由）

-- ---------- PostgREST から使えるように ----------
grant usage on schema info to anon, authenticated, service_role;
grant all on all tables in schema info to anon, authenticated, service_role;
grant all on all routines in schema info to anon, authenticated, service_role;
grant all on all sequences in schema info to anon, authenticated, service_role;
alter default privileges in schema info grant all on tables to anon, authenticated, service_role;
