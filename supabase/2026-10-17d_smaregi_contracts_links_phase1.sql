-- =====================================================================
-- スマレジ複数契約対応 Phase①②＋⑤の前半（担当D・2026-10-17・事前報告用・未適用）
-- 設計: docs/設計メモ_スマレジ複数契約対応_2026-10-15.md §3／指示書_黒霧屋運営変更…§3／司令塔決定（sf_payroll_syncの契約キー）
-- =====================================================================
-- 内容（すべて「追加」。既存の動作は変えない＝この時点では既存行はすべてトーホー契約・1契約のまま）:
--  ① smaregi_contracts: 契約マスタ（トーホー=sez093z1をseed。LiveGateは契約IDが届いたらINSERT）
--  ② employee_smaregi_links: 従業員×契約リンク（同一user_idに有効行2本可＝兼務/移籍期間）。employee_profiles.smaregi_staff_idは
--     「主契約の写し」として残し、既存の連携（smaregi-sync等）がそこへ書いた値をトリガーでトーホーのリンクへ反映する（互換）
--  ⑤ sf_payroll_sync.contract_id: 新列（NOT NULL・既定=トーホー契約ID・既存行はトーホーで埋まる）。
--     新しい一意索引 (user_id, year_month, contract_id) を**追加**する。旧の一意制約 (user_id, year_month) は
--     この段階では**残す**（旧版の関数のupsertが壊れないため）。旧制約の削除はPhase2（別ファイル・LiveGate初回同期の直前）
-- 【影響】新規テーブル2・新規列1・新規索引1・トリガー1。既存の画面・関数・SQL関数の結果は変わらない（既存行はすべてcontract_id=トーホー）。
-- 【rollback】 drop trigger if exists employee_profiles_smaregi_link_sync on employee_profiles; drop function if exists sync_primary_smaregi_link();
--              drop index if exists sf_payroll_sync_user_ym_contract_key; alter table sf_payroll_sync drop column if exists contract_id;
--              drop table if exists employee_smaregi_links; drop table if exists smaregi_contracts;
-- 実行場所: Supabase SQL Editor（何度実行しても壊れません）
-- =====================================================================

create table if not exists public.smaregi_contracts (
  id uuid primary key default gen_random_uuid(),
  corporation_id uuid references public.corporations(id),
  contract_id text not null unique,           -- スマレジの契約ID（例 sez093z1）
  label text,
  corporation_hint text,                      -- store_external_mappings.corporation_hint と対応する識別子（'toho' / 'livegate'）。店舗IDは契約ごとに採番されるため、契約ごとの店舗対応の絞り込みに使う
  is_default boolean not null default false,  -- 既定の契約（corporation_hintがnullの既存マッピングはこの契約のもの＝互換。1つだけtrue）
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists smaregi_contracts_one_default_key on public.smaregi_contracts (is_default) where is_default;
insert into public.smaregi_contracts (corporation_id, contract_id, label, corporation_hint, is_default)
select c.id, 'sez093z1', 'トーホー（スマレジ・タイムカード本番）', 'toho', true
from public.corporations c where c.name = 'トーホー'
on conflict (contract_id) do nothing;

create table if not exists public.employee_smaregi_links (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  contract_id text not null references public.smaregi_contracts(contract_id),
  smaregi_staff_id text not null,
  effective_from date not null default current_date,
  effective_to date,                          -- null=現在も有効。移籍=旧契約の行に入れる／兼務追加=閉じない
  is_primary boolean not null default false,  -- 主契約（employee_profiles.smaregi_staff_idに写す）
  created_at timestamptz not null default now()
);
-- 同じ契約・同じスタッフIDの有効行は1つだけ／1人が同じ契約で有効なスタッフIDを2つ持たない（契約が違えば2本まで並ぶ＝兼務）
create unique index if not exists employee_smaregi_links_active_staff_key
  on public.employee_smaregi_links (contract_id, smaregi_staff_id) where effective_to is null;
create unique index if not exists employee_smaregi_links_active_user_contract_key
  on public.employee_smaregi_links (user_id, contract_id) where effective_to is null;
create index if not exists employee_smaregi_links_user_idx on public.employee_smaregi_links (user_id);

-- 既存の連携（employee_profiles.smaregi_staff_id）をトーホー契約のリンクへ写す
insert into public.employee_smaregi_links (user_id, contract_id, smaregi_staff_id, effective_from, is_primary)
select p.user_id, 'sez093z1', p.smaregi_staff_id, coalesce(p.hire_date, date '2000-01-01'), true
from public.employee_profiles p
where p.smaregi_staff_id is not null
on conflict do nothing;

-- 互換: 今後、既存のsmaregi-sync等がemployee_profiles.smaregi_staff_idを書き換えたら、トーホー契約のリンクへ反映する
create or replace function public.sync_primary_smaregi_link() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.smaregi_staff_id is distinct from old.smaregi_staff_id or tg_op = 'INSERT' then
    -- 旧い有効行を閉じる（値が変わった/外れた場合）
    update public.employee_smaregi_links set effective_to = current_date
      where user_id = new.user_id and contract_id = 'sez093z1' and effective_to is null
        and smaregi_staff_id is distinct from new.smaregi_staff_id;
    if new.smaregi_staff_id is not null then
      insert into public.employee_smaregi_links (user_id, contract_id, smaregi_staff_id, is_primary)
      values (new.user_id, 'sez093z1', new.smaregi_staff_id, true)
      on conflict do nothing;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists employee_profiles_smaregi_link_sync on public.employee_profiles;
create trigger employee_profiles_smaregi_link_sync after insert or update of smaregi_staff_id on public.employee_profiles
  for each row execute function public.sync_primary_smaregi_link();

alter table public.smaregi_contracts enable row level security;
alter table public.employee_smaregi_links enable row level security;
revoke all on public.smaregi_contracts, public.employee_smaregi_links from anon;
-- 読み取り: CEO/HQ/マスター/店長/チーム長（従業員編集の「スマレジ連携（契約ごと）」表示用）と本人。書き込みはservice_role経由のみ
drop policy if exists smaregi_contracts_read on public.smaregi_contracts;
create policy smaregi_contracts_read on public.smaregi_contracts for select to authenticated using (
  exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ','TEAM','TENCHO'))));
drop policy if exists employee_smaregi_links_read on public.employee_smaregi_links;
create policy employee_smaregi_links_read on public.employee_smaregi_links for select to authenticated using (
  user_id = auth.uid()
  or exists (select 1 from public.users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ','TEAM','TENCHO'))));

-- ⑤ sf_payroll_sync に契約列（既存行は既定値=トーホーで埋まる）。旧の一意制約はこの段階では残す
alter table public.sf_payroll_sync add column if not exists contract_id text not null default 'sez093z1';
comment on column public.sf_payroll_sync.contract_id is 'スマレジの契約ID（＝運営会社）。兼務の人は契約ごとに1行。Phase2で一意キーを (user_id, year_month, contract_id) に切替';
create unique index if not exists sf_payroll_sync_user_ym_contract_key on public.sf_payroll_sync (user_id, year_month, contract_id);
