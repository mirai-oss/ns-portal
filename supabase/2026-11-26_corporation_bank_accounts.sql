-- =====================================================================
-- 法人の振込先口座（正本）corporation_bank_accounts（担当F・2026-11-26）
--
-- 【事前報告】
-- 理由: 業務委託の精算などで「法人扱いの委託先（LiveGate・トーホー等）」へ振り込むための口座の置き場が正本に無い。
--       取引先の行を法人の代わりに作ると同じ会社が二重管理になるため、法人用の口座表を別に持つ。
-- 現構造: 取引先の口座は vendor_bank_accounts、従業員は payroll_bank_accounts。社内情報 info.bank_accounts は
--         銀行コード・名義カナが無く振込データに使えない。法人(corporations)の口座を持つ表は無い。
-- 変更（追加のみ）: 表 corporation_bank_accounts（列の形は vendor_bank_accounts と同じ・1法人につき「現在の口座」は1つ・
--         前の口座は履歴で残す）と、登録/停止の関数2つ。閲覧・編集は本部/社長/マスターのみ。ログインなし(anon)は不可。
--         管理用の鍵(service_role)は読める（精算の仕組みが参照する想定）。
-- 既存データへの影響: なし（既存の表・関数は変えない。データは入れない）。
-- 冪等。 rollback: drop function if exists public.smv2_set_corporation_bank_account(uuid,text,text,text,text,text,text,text),
--         public.smv2_close_corporation_bank_account(uuid); drop table if exists public.corporation_bank_accounts;
-- =====================================================================
create table if not exists public.corporation_bank_accounts (
  id uuid primary key default gen_random_uuid(),
  corporation_id uuid not null references public.corporations(id),
  bank_code text not null check (bank_code ~ '^[0-9]{4}$'),
  bank_name text not null,
  branch_code text not null check (branch_code ~ '^[0-9]{3}$'),
  branch_name text not null,
  account_type text not null default '1' check (account_type in ('1','2','4')), -- 1=普通 2=当座 4=貯蓄
  account_number text not null check (account_number ~ '^[0-9]{7}$'),
  account_holder_kana text not null,
  is_current boolean not null default true,
  valid_from date not null default ((now() at time zone 'Asia/Tokyo')::date),
  valid_to date,
  source text not null default 'manual',
  confirmed_at timestamptz,
  confirmed_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists corporation_bank_accounts_current_uq
  on public.corporation_bank_accounts (corporation_id) where is_current;
create index if not exists corporation_bank_accounts_corp_idx on public.corporation_bank_accounts (corporation_id);
comment on table public.corporation_bank_accounts is
  '法人の振込先口座（正本）。登録は smv2_set_corporation_bank_account。前の口座は is_current=false で残す（削除しない）';

alter table public.corporation_bank_accounts enable row level security;
-- Supabase の既定で anon/authenticated に全権限が付くため、いったん全部外して「読み取りだけ」を戻す（書き込みは関数経由）
revoke all on table public.corporation_bank_accounts from public, anon, authenticated;
grant select on table public.corporation_bank_accounts to authenticated;
drop policy if exists corporation_bank_accounts_select_admin on public.corporation_bank_accounts;
create policy corporation_bank_accounts_select_admin on public.corporation_bank_accounts
  for select to authenticated using (public.store_master_can_edit());

create or replace function public.smv2_set_corporation_bank_account(
  p_corporation_id uuid, p_bank_code text, p_bank_name text, p_branch_code text, p_branch_name text,
  p_account_type text, p_account_number text, p_account_holder_kana text
) returns uuid language plpgsql security definer set search_path to 'public' as $$
declare
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_bank text := regexp_replace(normalize(coalesce(p_bank_code,''), NFKC), '[[:space:]]', '', 'g');
  v_branch text := regexp_replace(normalize(coalesce(p_branch_code,''), NFKC), '[[:space:]]', '', 'g');
  v_num text := regexp_replace(normalize(coalesce(p_account_number,''), NFKC), '[[:space:]]', '', 'g');
  v_kana text := btrim(coalesce(p_account_holder_kana,''));
  v_id uuid;
begin
  if not store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  perform 1 from public.corporations where id = p_corporation_id for update;
  if not found then raise exception '法人が存在しません'; end if;
  if v_bank !~ '^[0-9]{4}$' then raise exception '銀行コードは4桁の数字で入力してください'; end if;
  if v_branch !~ '^[0-9]{3}$' then raise exception '支店コードは3桁の数字で入力してください'; end if;
  if v_num !~ '^[0-9]{1,7}$' then raise exception '口座番号は7桁以内の数字で入力してください'; end if;
  if coalesce(p_account_type,'') not in ('1','2','4') then raise exception '口座の種類が不正です'; end if;
  if nullif(btrim(coalesce(p_bank_name,'')),'') is null or nullif(btrim(coalesce(p_branch_name,'')),'') is null then
    raise exception '銀行名と支店名を入力してください'; end if;
  if v_kana = '' then raise exception '口座名義（カナ）を入力してください'; end if;

  update public.corporation_bank_accounts set is_current = false, valid_to = v_today, updated_at = now()
   where corporation_id = p_corporation_id and is_current;
  insert into public.corporation_bank_accounts
    (corporation_id, bank_code, bank_name, branch_code, branch_name, account_type, account_number,
     account_holder_kana, confirmed_at, confirmed_by)
  values (p_corporation_id, v_bank, btrim(p_bank_name), v_branch, btrim(p_branch_name), p_account_type,
          lpad(v_num, 7, '0'), v_kana, now(), auth.uid())
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.smv2_close_corporation_bank_account(p_id uuid)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not store_master_can_edit() then raise exception '権限がありません（本部/社長/マスターのみ）'; end if;
  update public.corporation_bank_accounts
     set is_current = false, valid_to = (now() at time zone 'Asia/Tokyo')::date, updated_at = now()
   where id = p_id and is_current;
  if not found then raise exception '対象の口座が見つからないか、すでに使われていません'; end if;
end $$;

revoke execute on function public.smv2_set_corporation_bank_account(uuid,text,text,text,text,text,text,text) from public, anon;
revoke execute on function public.smv2_close_corporation_bank_account(uuid) from public, anon;
grant execute on function public.smv2_set_corporation_bank_account(uuid,text,text,text,text,text,text,text) to authenticated, service_role;
grant execute on function public.smv2_close_corporation_bank_account(uuid) to authenticated, service_role;
