-- スマレジの「店舗ではない事業所」を比較・同期から外すための除外リスト（担当D・2026-10-17・ユーザー確定）
-- 背景: スマレジ・タイムカードの事業所ID 1「鳥一代　社員」は店舗ではなく「社員」の区分用の事業所（ユーザー確認済み）。
--   管理システムに対応する店舗が無いため、これを「対応が取れない事業所」として隔離すると、所属している人（15人）の
--   所属が一律に同期対象外になってしまう。除外リストに載せた事業所は、所属の比較・同期（初回の一致・今後の双方向同期）で
--   「存在しないもの」として扱う（人の所属は他の事業所＝店舗だけで比べる）。
-- 【影響】新規テーブル追加と、棚卸し用ビュー3本の作り直しのみ。既存の運用テーブルは変更しない。
-- 【rollback】 delete from smaregi_store_ignore; （ビューは 2026-10-17_staff_store_audit_base.sql を再実行すれば元に戻る）
create table if not exists public.smaregi_store_ignore (
  contract_id text not null,
  store_id text not null,            -- スマレジの事業所ID
  reason text,
  created_at timestamptz not null default now(),
  primary key (contract_id, store_id)
);
alter table public.smaregi_store_ignore enable row level security;
revoke all on public.smaregi_store_ignore from anon, authenticated;
insert into public.smaregi_store_ignore (contract_id, store_id, reason)
select s.contract_id, s.store_id, '店舗ではなく「社員」の区分用の事業所（ユーザー確認 2026-10-17）'
from public.smaregi_stores_snapshot s where s.store_id = '1'
on conflict do nothing;

-- 差分ビュー（除外リストの事業所を無視。スマレジに「店舗の所属」が1つも無い人は、置換で全店舗が外れるのを防ぐため
--   差分対象から外し、別ビュー(nosmaregi)に出す）
create or replace view public.v_staff_store_audit_rows as
with link as (
  select p.user_id, p.smaregi_staff_id from public.employee_profiles p where p.smaregi_staff_id is not null
),
ign as (select contract_id, store_id from public.smaregi_store_ignore),
mapped as (
  select e.external_store_id as smaregi_store_id, e.store_id
  from public.store_external_mappings e
  where e.source_system = 'smaregi_timecard' and coalesce(e.is_active, true)
    and (e.effective_to is null or e.effective_to >= current_date)
),
snap as (
  select s.* from public.smaregi_staff_stores_snapshot s
  where not exists (select 1 from ign i where i.contract_id = s.contract_id and i.store_id = s.smaregi_store_id)
),
sm as (
  select l.user_id, m.store_id, s.smaregi_store_id, s.contract_id
  from snap s join link l on l.smaregi_staff_id = s.smaregi_staff_id
  join mapped m on m.smaregi_store_id = s.smaregi_store_id
),
has_sm as (select distinct user_id from sm),
mg as (
  select us.user_id, us.store_id, us.is_primary
  from public.user_stores us join link l on l.user_id = us.user_id
  where us.user_id in (select user_id from has_sm)
)
select
  coalesce(sm.user_id, mg.user_id) as user_id,
  u.name as user_name,
  coalesce(sm.store_id, mg.store_id) as store_id,
  st.name as store_name,
  case when sm.user_id is not null and mg.user_id is not null then 'keep'
       when sm.user_id is not null then 'add'
       else 'remove' end as change,
  mg.is_primary as was_primary
from sm
full join mg on mg.user_id = sm.user_id and mg.store_id = sm.store_id
left join public.users u on u.id = coalesce(sm.user_id, mg.user_id)
left join public.stores st on st.id = coalesce(sm.store_id, mg.store_id);

create or replace view public.v_staff_store_audit_unmapped as
select s.contract_id, s.store_id as smaregi_store_id, s.store_code, s.store_name,
       (select count(*) from public.smaregi_staff_stores_snapshot x where x.contract_id = s.contract_id and x.smaregi_store_id = s.store_id) as staff_count
from public.smaregi_stores_snapshot s
where not exists (select 1 from public.smaregi_store_ignore i where i.contract_id = s.contract_id and i.store_id = s.store_id)
  and not exists (
  select 1 from public.store_external_mappings e
  where e.source_system = 'smaregi_timecard' and coalesce(e.is_active, true) and e.external_store_id = s.store_id
);

-- スマレジ連携済みなのに、「店舗の所属」（除外リストの事業所を除く）が1つも無い人（置換すると所属が全部消えるため自動では触らない）
create or replace view public.v_staff_store_audit_nosmaregi as
select p.user_id, u.name as user_name, p.smaregi_staff_id,
       (select count(*) from public.user_stores us where us.user_id = p.user_id) as mgmt_store_count
from public.employee_profiles p
join public.users u on u.id = p.user_id
where p.smaregi_staff_id is not null
  and not exists (
    select 1 from public.smaregi_staff_stores_snapshot s
    where s.smaregi_staff_id = p.smaregi_staff_id
      and not exists (select 1 from public.smaregi_store_ignore i where i.contract_id = s.contract_id and i.store_id = s.smaregi_store_id)
  );

revoke all on public.v_staff_store_audit_rows, public.v_staff_store_audit_unmapped, public.v_staff_store_audit_nosmaregi from anon, authenticated;
