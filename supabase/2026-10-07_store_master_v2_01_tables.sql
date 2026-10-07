-- =====================================================================
-- 店舗・法人・運営関係の正本 Phase1（土台）— ① 表・列・seed・バックフィル
-- 担当F ／ 指示書: docs/実装指示書_担当F_店舗法人正本Phase1_2026-10-07.md
-- 設計の正:       docs/設計書_店舗法人運営関係の正本再設計_2026-10-07.md（v1.0・Sync9）
--
-- 【事前報告様式（DB変更）】
-- 理由: 「1店舗=1法人（stores.corporation_id）」では表せない関係（賃貸借名義≠運営法人／外部への運営委託／
--       売上入金先≠運営法人／外部システムごとの店舗名・ID／1店舗に複数ブランド）の正本を作る土台。
--       ゴール＝請求書を読み込んだら店舗コード・店舗名からその店舗と判断し、仕訳・PL反映まで自動で起こせること。
-- 現構造（2026-10-07 本番を読み取り専用で確認）:
--   corporations 4社（livegate/sk/nstyle/toho）／stores 14行（通常12＋「本部」store_no=99＋「セントラルキッチン」store_no=100）／
--   store_aliases 45件（alias主キー=全システム共通で一意）／vendors 72件（MostFun・FAM Diningは未登録）／
--   kd_unresolved_names 16件（open）／delivery_store_map 4件。
-- 変更（すべて「追加」。既存の列・行・名称・ポリシー・他システムの読み取りは不変）:
--   (1) corporations に列追加 legal_name / display_name / is_group_company ＋ 4社seed
--   (2) corporation_aliases 新設（法人の表記ゆれ→法人）
--   (3) stores に列追加 location_type / display_name。既存「本部」「セントラルキッチン」行は更新のみ（name不変）。
--       新規行は「N-Style 本社」1行だけ（is_active=false）
--   (4) brands / store_brand_relations 新設（stores.signs からバックフィル。info.brands は触らない）
--   (5) vendor_roles 新設＋ vendors に MostFun / FAM Dining を追加（会計用列は空）→ role_type='operator'
--   (6) store_operation_relations 新設（期間の重複禁止トリガー付き）＋ seed（直営7＋非直営5）
--   (7) store_external_mappings 新設＋ store_aliases / stores各列 / delivery_store_map からバックフィル
--   RLS: 新表はすべて「認証済み=読み取りのみ」。書き込みは次ファイル(02)のRPC（本部/社長/マスターのみ）経由。
-- 既存データへの影響: なし（既存行は location_type/display_name を足す更新と、新行追加のみ）。
-- 何も切り替えない: どのシステムの読み取り先もこのPhase1では変えない。
-- 冪等: 何度流しても壊れない（if not exists / on conflict do nothing / where not exists）。
-- rollback: ファイル末尾のコメント参照。
-- =====================================================================

-- ---------------------------------------------------------------------
-- 共通: 編集権限の判定（本部/社長/マスター）
-- ---------------------------------------------------------------------
create or replace function public.store_master_can_edit()
returns boolean language sql stable security definer
set search_path to 'public' as $$
  select coalesce((
    select u.is_master or u.role in ('CEO','HQ')
    from public.users u where u.id = auth.uid() and u.is_active
  ), false);
$$;
revoke all on function public.store_master_can_edit() from public;
grant execute on function public.store_master_can_edit() to authenticated, service_role;

-- ---------------------------------------------------------------------
-- (1) corporations 列追加＋seed
-- ---------------------------------------------------------------------
alter table public.corporations add column if not exists legal_name text;
alter table public.corporations add column if not exists display_name text;
alter table public.corporations add column if not exists is_group_company boolean not null default false;

update public.corporations set legal_name='株式会社LiveGate',            display_name='LiveGate', is_group_company=true
  where corp_code='livegate' and legal_name is null;
update public.corporations set legal_name='株式会社SKコンサルティング',  display_name='SK',       is_group_company=true
  where corp_code='sk' and legal_name is null;
update public.corporations set legal_name='株式会社N-Style',             display_name='N-Style',  is_group_company=true
  where corp_code='nstyle' and legal_name is null;
update public.corporations set legal_name='有限会社トーホーエージェンシー', display_name='トーホー', is_group_company=true
  where corp_code='toho' and legal_name is null;

-- ---------------------------------------------------------------------
-- (2) corporation_aliases
-- ---------------------------------------------------------------------
create table if not exists public.corporation_aliases (
  id uuid primary key default gen_random_uuid(),
  corporation_id uuid not null references public.corporations(id),
  alias text not null,
  source text not null default 'manual',
  created_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  is_active boolean not null default true,
  unique (alias, source)
);
create index if not exists corporation_aliases_corp_idx on public.corporation_aliases (corporation_id);
comment on table public.corporation_aliases is
  '法人の表記ゆれ（請求書OCRの会社名等）→法人。新旧表記は同じ法人に複数登録する。resolve_storeのp_corp_hint解決にも使う';

insert into public.corporation_aliases (corporation_id, alias, source)
select c.id, a.alias, 'seed'
from (values
  ('toho','有限会社トーホーエージェンシー'),('toho','（有）トーホーエージェンシー'),('toho','(有)トーホーエージェンシー'),
  ('toho','㈲トーホーエージェンシー'),('toho','トーホーエージェンシー'),('toho','トーホー'),
  ('livegate','株式会社LiveGate'),('livegate','（株）LiveGate'),('livegate','㈱LiveGate'),('livegate','LiveGate'),
  ('sk','株式会社SKコンサルティング'),('sk','（株）SKコンサルティング'),('sk','㈱SKコンサルティング'),
  ('sk','SKコンサルティング'),('sk','SK'),
  ('nstyle','株式会社N-Style'),('nstyle','（株）N-Style'),('nstyle','㈱N-Style'),('nstyle','N-Style')
) as a(corp_code, alias)
join public.corporations c on c.corp_code = a.corp_code
on conflict do nothing;

-- ---------------------------------------------------------------------
-- (3) stores 列追加＋既存行の更新＋N-Style本社
-- ---------------------------------------------------------------------
alter table public.stores add column if not exists location_type text not null default 'store';
alter table public.stores add column if not exists display_name text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'stores_location_type_check') then
    alter table public.stores add constraint stores_location_type_check
      check (location_type in ('store','hq','central_kitchen','office','warehouse'));
  end if;
end $$;

-- 既存行を再利用（nameは変えない＝GAS側の文字列一致を壊さない）
update public.stores set location_type='hq', display_name='トーホー 本社'
  where store_no='99' and name='本部' and location_type='store' and display_name is null;
update public.stores set location_type='central_kitchen', display_name='田町セントラルキッチン'
  where name='セントラルキッチン' and location_type='store' and display_name is null;

-- 新規はN-Style本社の1行だけ（is_active=false。store_noは特殊行の連番 99,100 の次＝101）
insert into public.stores (name, sort_order, is_active, corporation_id, store_no, location_type, display_name)
select 'N-Style 本社', 97, false, c.id, '101', 'hq', 'N-Style 本社'
from public.corporations c
where c.corp_code='nstyle'
  and not exists (select 1 from public.stores s where s.name='N-Style 本社');

-- ---------------------------------------------------------------------
-- (4) brands / store_brand_relations（stores.signs からバックフィル）
-- ---------------------------------------------------------------------
create table if not exists public.brands (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  display_name text,
  is_active boolean not null default true,
  legacy_info_id uuid,          -- Phase1後に info.brands との対応付けに使う（Phase1では空）
  created_at timestamptz not null default now()
);
create table if not exists public.store_brand_relations (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id),
  brand_id uuid not null references public.brands(id),
  is_primary boolean not null default false,
  effective_from date,          -- null=当初から（開始日不明）
  effective_to date,            -- null=現在も有効
  created_at timestamptz not null default now()
);
create unique index if not exists store_brand_relations_open_uq
  on public.store_brand_relations (store_id, brand_id) where effective_to is null;
create index if not exists store_brand_relations_brand_idx on public.store_brand_relations (brand_id);

insert into public.brands (name, display_name)
select distinct sg, sg from public.stores s, unnest(s.signs) as sg
where s.signs is not null and btrim(sg) <> ''
on conflict (name) do nothing;

insert into public.store_brand_relations (store_id, brand_id, is_primary)
select s.id, b.id, (t.ord = 1)
from public.stores s
cross join lateral unnest(s.signs) with ordinality as t(sg, ord)
join public.brands b on b.name = t.sg
where s.signs is not null
  and not exists (select 1 from public.store_brand_relations r
                  where r.store_id = s.id and r.brand_id = b.id and r.effective_to is null);

-- ---------------------------------------------------------------------
-- (5) vendor_roles ＋ MostFun / FAM Dining
-- ---------------------------------------------------------------------
create table if not exists public.vendor_roles (
  vendor_id uuid not null references public.vendors(id),
  role_type text not null check (role_type in ('operator','supplier','sublessee','landlord','advertising_vendor')),
  effective_from date,
  effective_to date,
  created_at timestamptz not null default now(),
  primary key (vendor_id, role_type)
);

insert into public.vendors (name, notes)
select v.name, '運営受託会社（店舗法人正本Phase1で追加。正式な法人名・請求先情報は未入力）'
from (values ('MostFun'),('FAM Dining')) as v(name)
where not exists (
  select 1 from public.vendors x
  where lower(replace(x.name,' ','')) like '%' || lower(replace(v.name,' ','')) || '%'
);

insert into public.vendor_roles (vendor_id, role_type)
select x.id, 'operator'
from public.vendors x
where lower(replace(x.name,' ','')) like '%mostfun%'
   or lower(replace(x.name,' ','')) like '%famdining%'
on conflict do nothing;

-- ---------------------------------------------------------------------
-- (6) store_operation_relations（期間履歴・上書き禁止）
--   effective_to は「最終日（含む）」。null=現在も有効。変更時は旧行の effective_to を入れて新行を追加。
-- ---------------------------------------------------------------------
create table if not exists public.store_operation_relations (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id),
  relation_type text not null check (relation_type in ('direct','outsourcing','sublease')),
  lease_entity_type    text not null check (lease_entity_type    in ('corporation','vendor')),
  lease_entity_id      uuid not null,   -- 賃貸借名義
  operator_entity_type text not null check (operator_entity_type in ('corporation','vendor')),
  operator_entity_id   uuid not null,   -- 運営主体
  revenue_entity_type  text not null check (revenue_entity_type  in ('corporation','vendor')),
  revenue_entity_id    uuid not null,   -- 売上入金先
  effective_from date not null,
  effective_to date,
  contract_term_months int,
  auto_renew boolean not null default false,
  note text,
  created_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  check (effective_to is null or effective_to >= effective_from)
);
create index if not exists store_operation_relations_store_idx on public.store_operation_relations (store_id, effective_from);

-- エンティティの実在確認＋同一店舗の期間重複禁止（polymorphicなためFKの代わりにトリガーで守る）
create or replace function public.store_operation_relations_guard()
returns trigger language plpgsql as $$
declare
  v_ok boolean;
begin
  select (case new.lease_entity_type    when 'corporation' then exists(select 1 from public.corporations where id=new.lease_entity_id)
                                        else exists(select 1 from public.vendors where id=new.lease_entity_id) end)
     and (case new.operator_entity_type when 'corporation' then exists(select 1 from public.corporations where id=new.operator_entity_id)
                                        else exists(select 1 from public.vendors where id=new.operator_entity_id) end)
     and (case new.revenue_entity_type  when 'corporation' then exists(select 1 from public.corporations where id=new.revenue_entity_id)
                                        else exists(select 1 from public.vendors where id=new.revenue_entity_id) end)
    into v_ok;
  if not v_ok then
    raise exception '名義・運営・入金先のいずれかが、法人/取引先に存在しません';
  end if;

  if exists (
    select 1 from public.store_operation_relations r
    where r.store_id = new.store_id
      and r.id is distinct from new.id
      and r.effective_from <= coalesce(new.effective_to, date '9999-12-31')
      and new.effective_from <= coalesce(r.effective_to, date '9999-12-31')
  ) then
    raise exception '同じ店舗で期間が重なる運営関係は登録できません（旧関係に終了日を入れてから新しい関係を追加してください）';
  end if;
  return new;
end $$;
drop trigger if exists store_operation_relations_guard_trg on public.store_operation_relations;
create trigger store_operation_relations_guard_trg
  before insert or update on public.store_operation_relations
  for each row execute function public.store_operation_relations_guard();

-- seed: 直営7店舗（名義・運営・入金=トーホー）。開業日が不明のため effective_from は 2026-03-01 で統一（備考に明記）
insert into public.store_operation_relations
  (store_id, relation_type, lease_entity_type, lease_entity_id, operator_entity_type, operator_entity_id,
   revenue_entity_type, revenue_entity_id, effective_from, note)
select s.id, 'direct', 'corporation', c.id, 'corporation', c.id, 'corporation', c.id, date '2026-03-01',
       'Phase1 seed: 直営。開業日が不明のため 2026-03-01 で統一（暫定）'
from public.stores s
join public.corporations c on c.corp_code='toho'
where s.name in ('鳥一代 本店','鳥一代 はなれ','芝の鳥一代','鳥一代 恵比寿','鳥一代 新橋','鶏武者 新横浜','鶏武者 川崎店')
  and not exists (select 1 from public.store_operation_relations r where r.store_id = s.id);

-- seed: 黒霧屋 新横浜（名義N-Style・運営トーホー・入金N-Style・outsourcing）
insert into public.store_operation_relations
  (store_id, relation_type, lease_entity_type, lease_entity_id, operator_entity_type, operator_entity_id,
   revenue_entity_type, revenue_entity_id, effective_from, contract_term_months, auto_renew, note)
select s.id, 'outsourcing', 'corporation', n.id, 'corporation', t.id, 'corporation', n.id, date '2026-03-01', 12, true,
       'Phase1 seed: 契約開始日・12か月・自動更新はユーザー確定値（契約書の確認は範囲外）'
from public.stores s
join public.corporations n on n.corp_code='nstyle'
join public.corporations t on t.corp_code='toho'
where s.name='黒霧屋 新横浜'
  and not exists (select 1 from public.store_operation_relations r where r.store_id = s.id);

-- seed: じんべぇ 川崎・新横浜・エース 本厚木（運営=MostFun）／秋葉原 肉寿司（運営=FAM Dining）
insert into public.store_operation_relations
  (store_id, relation_type, lease_entity_type, lease_entity_id, operator_entity_type, operator_entity_id,
   revenue_entity_type, revenue_entity_id, effective_from, contract_term_months, auto_renew, note)
select s.id, 'outsourcing', 'corporation', n.id, 'vendor', v.id, 'corporation', n.id, date '2026-03-01', 12, true,
       'Phase1 seed: 契約開始日・12か月・自動更新はユーザー確定値（契約書の確認は範囲外）'
from public.stores s
join public.corporations n on n.corp_code='nstyle'
join lateral (
  select x.id from public.vendors x
  where lower(replace(x.name,' ','')) like (case when s.name='秋葉原 肉寿司' then '%famdining%' else '%mostfun%' end)
  order by x.created_at limit 1
) v on true
where s.name in ('じんべぇ 川崎','じんべぇ 新横浜','エース 本厚木','秋葉原 肉寿司')
  and not exists (select 1 from public.store_operation_relations r where r.store_id = s.id);

-- ---------------------------------------------------------------------
-- (7) store_external_mappings ＋ バックフィル
-- ---------------------------------------------------------------------
create table if not exists public.store_external_mappings (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores(id),
  brand_id uuid references public.brands(id),
  source_system text not null check (source_system in
    ('smaregi','smaregi_timecard','invoice','tabelog','hotpepper','gurunavi','gbp','reservation','payroll',
     'settlement','ad','delivery','dashboard','legacy_alias')),
  external_store_id text,
  external_store_code text,
  external_store_name text,
  corporation_hint text,        -- corp_code（例 'toho'）。同名の別法人店舗の絞り込み／stores.corporation_idが空の拠点の法人補完に使う
  vendor_id uuid references public.vendors(id),
  effective_from date,
  effective_to date,
  created_by uuid references public.users(id),
  created_at timestamptz not null default now(),
  is_active boolean not null default true,
  note text
);
create unique index if not exists store_external_mappings_uq_id
  on public.store_external_mappings (source_system, external_store_id) where external_store_id is not null;
create unique index if not exists store_external_mappings_uq_name
  on public.store_external_mappings (source_system, external_store_name) where external_store_name is not null;
create index if not exists store_external_mappings_store_idx on public.store_external_mappings (store_id);
comment on table public.store_external_mappings is
  '外部システムごとの店舗ID/コード/名称→店舗。同じ名前が別の意味になる外部名（例: スマレジの「本部」）はここへ（store_aliasesはalias主キー=全システム共通のため不可）';

-- 「本部」= トーホー本社（スマレジ・タイムカードの事業所ID=7）。グローバル別名にはしない
insert into public.store_external_mappings
  (store_id, source_system, external_store_id, external_store_name, corporation_hint, note)
select s.id, 'smaregi_timecard', '7', '本部', 'toho', 'Phase1 seed: 本部=トーホー本社'
from public.stores s where s.store_no='99' and s.name='本部'
on conflict do nothing;

-- stores.smaregi_store_id → smaregi / smaregi_timecard（IDのみ）
insert into public.store_external_mappings (store_id, source_system, external_store_id, note)
select s.id, ss.sys, s.smaregi_store_id, 'backfill:stores.smaregi_store_id'
from public.stores s cross join (values ('smaregi'),('smaregi_timecard')) as ss(sys)
where s.smaregi_store_id is not null and btrim(s.smaregi_store_id) <> ''
on conflict do nothing;

-- stores.seisan_store_name → settlement / mf_department_name → payroll / dash_store_name → dashboard
insert into public.store_external_mappings (store_id, source_system, external_store_name, note)
select s.id, 'settlement', s.seisan_store_name, 'backfill:stores.seisan_store_name'
from public.stores s where s.seisan_store_name is not null and btrim(s.seisan_store_name) <> ''
on conflict do nothing;

-- mf_department_name「本社」は 本部 と セントラルキッチン の2行が同名＝曖昧。本部（トーホー本社）だけ登録し、CKは未登録（要確認）
insert into public.store_external_mappings (store_id, source_system, external_store_name, note)
select s.id, 'payroll', s.mf_department_name, 'backfill:stores.mf_department_name'
from public.stores s
where s.mf_department_name is not null and btrim(s.mf_department_name) <> ''
order by (s.store_no='99') desc, s.store_no
on conflict do nothing;

insert into public.store_external_mappings (store_id, source_system, external_store_name, note)
select s.id, 'dashboard', s.dash_store_name, 'backfill:stores.dash_store_name'
from public.stores s where s.dash_store_name is not null and btrim(s.dash_store_name) <> ''
on conflict do nothing;

-- store_aliases → source/kind から source_system を決める（不明は legacy_alias）
insert into public.store_external_mappings (store_id, source_system, external_store_name, note)
select a.store_id,
       case
         when a.source = 'smaregi_timecard' then 'smaregi_timecard'
         when a.source like '精算%'          then 'settlement'
         when a.source like '広告%'          then 'ad'
         when a.source like 'Google%'        then 'gbp'
         else 'legacy_alias'
       end,
       a.alias,
       'backfill:store_aliases(source=' || a.source || ',kind=' || coalesce(a.kind,'') || ')'
from public.store_aliases a
on conflict do nothing;

-- delivery_store_map → delivery（チャネル名は note に保持）
insert into public.store_external_mappings (store_id, source_system, external_store_id, external_store_name, is_active, note)
select d.store_id, 'delivery', d.channel_store_id, d.channel_store_name, coalesce(d.active, true),
       'backfill:delivery_store_map(channel=' || d.channel || ')'
from public.delivery_store_map d
on conflict do nothing;

-- ---------------------------------------------------------------------
-- RLS: 認証済み=読み取りのみ。書き込みは 02 のRPC（security definer）経由、service_roleはRLSを素通り
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['corporation_aliases','brands','store_brand_relations','vendor_roles',
                           'store_operation_relations','store_external_mappings']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_select_auth', t);
    execute format('create policy %I on public.%I for select to authenticated using (true)', t || '_select_auth', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- rollback（必要時のみ・新設物だけを消す。既存列/既存行は触らない）:
--   drop table if exists public.store_external_mappings, public.store_operation_relations, public.vendor_roles,
--     public.store_brand_relations, public.brands, public.corporation_aliases cascade;
--   drop function if exists public.store_operation_relations_guard();
--   alter table public.corporations drop column if exists legal_name, drop column if exists display_name, drop column if exists is_group_company;
--   delete from public.stores where name='N-Style 本社' and store_no='101';
--   update public.stores set location_type='store', display_name=null where store_no in ('99','100');
--   alter table public.stores drop constraint if exists stores_location_type_check;
--   alter table public.stores drop column if exists location_type, drop column if exists display_name;
--   delete from public.vendors where name in ('MostFun','FAM Dining') and notes like '運営受託会社（店舗法人正本Phase1%';
-- ---------------------------------------------------------------------
