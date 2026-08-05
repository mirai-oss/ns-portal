-- ============================================================
-- 社内情報管理システム → ハブ(info スキーマ) 構造移送
-- 生成: gen_info_ddl.py（元DB wciefkpooncglahqdtmu の public を写像）
-- 冪等: create schema/table if not exists
-- ============================================================
create schema if not exists info;

create table if not exists info."roles" (
  "id" uuid default gen_random_uuid() not null,
  "name" text not null,
  constraint "roles_pkey" PRIMARY KEY (id),
  constraint "roles_name_key" UNIQUE (name)
);

create table if not exists info."profiles" (
  "id" uuid not null,
  "name" text not null,
  "role_id" uuid,
  "is_master" boolean default false not null,
  "is_active" boolean default true not null,
  "created_at" timestamp with time zone default now() not null,
  "email" text,
  constraint "profiles_pkey" PRIMARY KEY (id)
);

create table if not exists info."audit_logs" (
  "id" bigint generated always as identity not null,
  "user_id" uuid,
  "action" text not null,
  "target" text,
  "detail" jsonb,
  "created_at" timestamp with time zone default now() not null,
  constraint "audit_logs_pkey" PRIMARY KEY (id)
);

create table if not exists info."corporations" (
  "id" uuid default gen_random_uuid() not null,
  "code" text not null,
  "name" text not null,
  "created_at" timestamp with time zone default now() not null,
  "postal_code" text,
  "address" text,
  "representative" text,
  "established_on" date,
  "phone" text,
  "fax" text,
  "corporate_number" text,
  "invoice_number" text,
  "capital" text,
  "emp_insurance_number" text,
  "labor_insurance_number" text,
  "rep_address" text,
  "rep_birth_date" date,
  "rep_phone" text,
  "memo" text,
  constraint "corporations_pkey" PRIMARY KEY (id),
  constraint "corporations_code_key" UNIQUE (code)
);

create table if not exists info."bank_accounts" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "bank_name" text not null,
  "branch" text,
  "account_type" text default '普通'::text,
  "account_number" text not null,
  "purpose" text,
  "has_netbank" boolean default false not null,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  "status" text default '使用中'::text not null,
  constraint "bank_accounts_pkey" PRIMARY KEY (id)
);

create table if not exists info."brands" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "name" text not null,
  "created_at" timestamp with time zone default now() not null,
  constraint "brands_pkey" PRIMARY KEY (id)
);

create table if not exists info."categories" (
  "id" text not null,
  "name" text not null,
  "sort_order" integer not null,
  constraint "categories_pkey" PRIMARY KEY (id)
);

create table if not exists info."credentials" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "category" text default 'その他'::text not null,
  "service_name" text not null,
  "login_url" text,
  "username" text,
  "memo" text,
  "media_plan" text,
  "media_contact_name" text,
  "media_contact_phone" text,
  "media_contact_email" text,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  "status" text default '使用中'::text not null,
  constraint "credentials_pkey" PRIMARY KEY (id)
);

create table if not exists info."credential_secret_history" (
  "id" bigint generated always as identity not null,
  "credential_id" uuid not null,
  "secret" text not null,
  "replaced_at" timestamp with time zone default now() not null,
  "replaced_by" uuid,
  constraint "credential_secret_history_pkey" PRIMARY KEY (id)
);

create table if not exists info."credential_secrets" (
  "credential_id" uuid not null,
  "secret" text not null,
  constraint "credential_secrets_pkey" PRIMARY KEY (credential_id)
);

create table if not exists info."stores" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "brand_id" uuid,
  "store_code" text not null,
  "name" text not null,
  "area" text,
  "is_active" boolean default true not null,
  "created_at" timestamp with time zone default now() not null,
  "postal_code" text,
  "address" text,
  "building" text,
  "phone" text,
  "fax" text,
  "official_url" text,
  "access_info" text,
  "manager_name" text,
  "business_hours" text,
  "emergency_contact" text,
  "postbox_info" text,
  "memo" text,
  constraint "stores_pkey" PRIMARY KEY (id),
  constraint "stores_store_code_key" UNIQUE (store_code)
);

create table if not exists info."credential_stores" (
  "credential_id" uuid not null,
  "store_id" uuid not null,
  constraint "credential_stores_pkey" PRIMARY KEY (credential_id, store_id)
);

create table if not exists info."documents" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "store_id" uuid,
  "title" text not null,
  "kind" text default 'その他'::text not null,
  "file_path" text not null,
  "mime_type" text,
  "size_bytes" bigint,
  "created_at" timestamp with time zone default now() not null,
  constraint "documents_pkey" PRIMARY KEY (id)
);

create table if not exists info."deadlines" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "store_id" uuid,
  "title" text not null,
  "due_date" date not null,
  "memo" text,
  "created_at" timestamp with time zone default now() not null,
  "document_id" uuid,
  constraint "deadlines_pkey" PRIMARY KEY (id)
);

create table if not exists info."employees" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "store_id" uuid,
  "name" text not null,
  "kana" text,
  "gender" text,
  "birth_date" date,
  "job" text,
  "role_title" text,
  "employment_type" text default '正社員'::text not null,
  "hired_on" date,
  "phone" text,
  "address" text,
  "nationality" text,
  "status" text default '在籍'::text not null,
  "memo" text,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  constraint "employees_pkey" PRIMARY KEY (id)
);

create table if not exists info."employee_salaries" (
  "employee_id" uuid not null,
  "base_salary" bigint,
  "incentive" bigint,
  "bonus_summer" bigint,
  "bonus_winter" bigint,
  "annual_income" bigint,
  "commute_allowance" bigint,
  "updated_at" timestamp with time zone default now() not null,
  constraint "employee_salaries_pkey" PRIMARY KEY (employee_id)
);

create table if not exists info."loans" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "bank_name" text not null,
  "loan_type" text,
  "principal" bigint not null,
  "annual_rate" numeric default 0 not null,
  "start_month" date not null,
  "months" integer not null,
  "monthly_principal" bigint,
  "memo" text,
  "created_at" timestamp with time zone default now() not null,
  "repayment_method" text default '元金均等'::text not null,
  constraint "loans_pkey" PRIMARY KEY (id)
);

create table if not exists info."photos" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "store_id" uuid,
  "category" text default 'その他'::text not null,
  "title" text,
  "file_path" text not null,
  "created_at" timestamp with time zone default now() not null,
  "original_url" text,
  "tags" text,
  constraint "photos_pkey" PRIMARY KEY (id)
);

create table if not exists info."properties" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "store_id" uuid,
  "management_company" text,
  "mgmt_phone" text,
  "mgmt_contact" text,
  "mgmt_mobile" text,
  "rent" bigint,
  "tsubo" numeric,
  "contract_type" text,
  "contract_date" date,
  "renewal_date" date,
  "deposit" text,
  "amortization" text,
  "landlord_name" text,
  "landlord_phone" text,
  "memo" text,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  "document_id" uuid,
  constraint "properties_pkey" PRIMARY KEY (id)
);

create table if not exists info."real_estate_properties" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "name" text not null,
  "postal_code" text,
  "address" text,
  "acquired_on" date,
  "acquisition_price" bigint,
  "loan_id" uuid,
  "mgmt_fee" bigint default 0 not null,
  "other_cost" bigint default 0 not null,
  "memo" text,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  constraint "real_estate_properties_pkey" PRIMARY KEY (id)
);

create table if not exists info."real_estate_units" (
  "id" uuid default gen_random_uuid() not null,
  "property_id" uuid not null,
  "unit_name" text not null,
  "tenant_name" text,
  "rent" bigint default 0 not null,
  "status" text default '入居中'::text not null,
  "lease_renewal" date,
  "memo" text,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  constraint "real_estate_units_pkey" PRIMARY KEY (id)
);

create table if not exists info."role_corporations" (
  "role_id" uuid not null,
  "corporation_id" uuid not null,
  constraint "role_corporations_pkey" PRIMARY KEY (role_id, corporation_id)
);

create table if not exists info."role_permissions" (
  "role_id" uuid not null,
  "category_id" text not null,
  "permission" text default 'none'::text not null,
  constraint "role_permissions_permission_check" CHECK ((permission = ANY (ARRAY['none'::text, 'view'::text, 'edit'::text]))),
  constraint "role_permissions_pkey" PRIMARY KEY (role_id, category_id)
);

create table if not exists info."suppliers" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "name" text not null,
  "kind" text,
  "phone" text,
  "contact_name" text,
  "contact_mobile" text,
  "contact2_name" text,
  "contact2_mobile" text,
  "email" text,
  "memo" text,
  "created_at" timestamp with time zone default now() not null,
  "status" text default '取引中'::text not null,
  "updated_at" timestamp with time zone default now() not null,
  constraint "suppliers_pkey" PRIMARY KEY (id)
);

create table if not exists info."user_corporations" (
  "user_id" uuid not null,
  "corporation_id" uuid not null,
  constraint "user_corporations_pkey" PRIMARY KEY (user_id, corporation_id)
);

create table if not exists info."user_permissions" (
  "user_id" uuid not null,
  "category_id" text not null,
  "permission" text not null,
  constraint "user_permissions_permission_check" CHECK ((permission = ANY (ARRAY['none'::text, 'view'::text, 'edit'::text]))),
  constraint "user_permissions_pkey" PRIMARY KEY (user_id, category_id)
);

create table if not exists info."user_stores" (
  "user_id" uuid not null,
  "store_id" uuid not null,
  constraint "user_stores_pkey" PRIMARY KEY (user_id, store_id)
);

create table if not exists info."utilities" (
  "id" uuid default gen_random_uuid() not null,
  "corporation_id" uuid not null,
  "store_id" uuid,
  "kind" text default 'その他'::text not null,
  "provider" text not null,
  "customer_number" text,
  "contact" text,
  "status" text default '使用中'::text not null,
  "memo" text,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  constraint "utilities_pkey" PRIMARY KEY (id)
);

-- ---------- 外部キー ----------
do $$ begin
  alter table info."audit_logs" add constraint "audit_logs_user_id_fkey" FOREIGN KEY (user_id) REFERENCES info."profiles"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."bank_accounts" add constraint "bank_accounts_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."brands" add constraint "brands_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."credential_secret_history" add constraint "credential_secret_history_replaced_by_fkey" FOREIGN KEY (replaced_by) REFERENCES info."profiles"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."credential_secret_history" add constraint "credential_secret_history_credential_id_fkey" FOREIGN KEY (credential_id) REFERENCES info."credentials"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."credential_secrets" add constraint "credential_secrets_credential_id_fkey" FOREIGN KEY (credential_id) REFERENCES info."credentials"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."credential_stores" add constraint "credential_stores_credential_id_fkey" FOREIGN KEY (credential_id) REFERENCES info."credentials"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."credential_stores" add constraint "credential_stores_store_id_fkey" FOREIGN KEY (store_id) REFERENCES info."stores"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."credentials" add constraint "credentials_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."deadlines" add constraint "deadlines_store_id_fkey" FOREIGN KEY (store_id) REFERENCES info."stores"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."deadlines" add constraint "deadlines_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."deadlines" add constraint "deadlines_document_id_fkey" FOREIGN KEY (document_id) REFERENCES info."documents"(id) ON DELETE SET NULL;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."documents" add constraint "documents_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."documents" add constraint "documents_store_id_fkey" FOREIGN KEY (store_id) REFERENCES info."stores"(id) ON DELETE SET NULL;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."employee_salaries" add constraint "employee_salaries_employee_id_fkey" FOREIGN KEY (employee_id) REFERENCES info."employees"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."employees" add constraint "employees_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."employees" add constraint "employees_store_id_fkey" FOREIGN KEY (store_id) REFERENCES info."stores"(id) ON DELETE SET NULL;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."loans" add constraint "loans_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."photos" add constraint "photos_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."photos" add constraint "photos_store_id_fkey" FOREIGN KEY (store_id) REFERENCES info."stores"(id) ON DELETE SET NULL;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."profiles" add constraint "profiles_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."profiles" add constraint "profiles_role_id_fkey" FOREIGN KEY (role_id) REFERENCES info."roles"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."properties" add constraint "properties_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."properties" add constraint "properties_document_id_fkey" FOREIGN KEY (document_id) REFERENCES info."documents"(id) ON DELETE SET NULL;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."properties" add constraint "properties_store_id_fkey" FOREIGN KEY (store_id) REFERENCES info."stores"(id) ON DELETE SET NULL;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."real_estate_properties" add constraint "real_estate_properties_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."real_estate_properties" add constraint "real_estate_properties_loan_id_fkey" FOREIGN KEY (loan_id) REFERENCES info."loans"(id) ON DELETE SET NULL;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."real_estate_units" add constraint "real_estate_units_property_id_fkey" FOREIGN KEY (property_id) REFERENCES info."real_estate_properties"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."role_corporations" add constraint "role_corporations_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."role_corporations" add constraint "role_corporations_role_id_fkey" FOREIGN KEY (role_id) REFERENCES info."roles"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."role_permissions" add constraint "role_permissions_category_id_fkey" FOREIGN KEY (category_id) REFERENCES info."categories"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."role_permissions" add constraint "role_permissions_role_id_fkey" FOREIGN KEY (role_id) REFERENCES info."roles"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."stores" add constraint "stores_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."stores" add constraint "stores_brand_id_fkey" FOREIGN KEY (brand_id) REFERENCES info."brands"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."suppliers" add constraint "suppliers_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."user_corporations" add constraint "user_corporations_user_id_fkey" FOREIGN KEY (user_id) REFERENCES info."profiles"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."user_corporations" add constraint "user_corporations_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."user_permissions" add constraint "user_permissions_user_id_fkey" FOREIGN KEY (user_id) REFERENCES info."profiles"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."user_permissions" add constraint "user_permissions_category_id_fkey" FOREIGN KEY (category_id) REFERENCES info."categories"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."user_stores" add constraint "user_stores_store_id_fkey" FOREIGN KEY (store_id) REFERENCES info."stores"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."user_stores" add constraint "user_stores_user_id_fkey" FOREIGN KEY (user_id) REFERENCES info."profiles"(id) ON DELETE CASCADE;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."utilities" add constraint "utilities_store_id_fkey" FOREIGN KEY (store_id) REFERENCES info."stores"(id) ON DELETE SET NULL;
exception when duplicate_object then null; when duplicate_table then null; end $$;
do $$ begin
  alter table info."utilities" add constraint "utilities_corporation_id_fkey" FOREIGN KEY (corporation_id) REFERENCES info."corporations"(id);
exception when duplicate_object then null; when duplicate_table then null; end $$;

-- ---------- インデックス ----------
