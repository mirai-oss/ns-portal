-- =====================================================================
-- 所属店舗の初回一致（スマレジ・タイムカードを正本）の棚卸し用の土台（担当D・2026-10-17）
-- 設計: docs/設計メモ_スマレジ複数契約対応_2026-10-15.md §11-4 ／ 指示書_黒霧屋運営変更…§10
-- =====================================================================
-- 目的: ①スマレジの「事業所×所属スタッフ」を読み取って保存する表（読み取り専用の関数 smaregi-staff-stores が書く）
--       ②管理システムの user_stores との差分を見る集計ビュー ③今後の双方向同期の台帳（staff_store_sync・今回は空のまま作るだけ）
-- 【影響】新規テーブル・ビュー追加のみ。既存テーブル（user_stores 等）は一切変更しない。
-- 【個人情報】スナップショットはスマレジのスタッフIDと事業所IDだけ（氏名は持たない）。差分ビューは氏名を含むため、
--   anon/authenticated から読めないようにしている（service_role・SQL実行者のみ）。差分の一覧はユーザー・司令塔へ渡す用で、
--   公開リポジトリ(ns-portal)には載せない。
-- 【rollback】 drop view if exists v_staff_store_audit_unmapped, v_staff_store_audit_nosmaregi, v_staff_store_audit_unlinked, v_staff_store_audit_rows;
--              drop table if exists staff_store_sync, smaregi_staff_stores_snapshot, smaregi_stores_snapshot;
-- 実行場所: Supabase SQL Editor（何度実行しても壊れません）
-- =====================================================================

create table if not exists public.smaregi_stores_snapshot (
  contract_id text not null,
  store_id text not null,            -- スマレジの事業所ID
  store_code text,
  store_name text,
  run_id uuid,
  fetched_at timestamptz not null default now(),
  primary key (contract_id, store_id)
);
create table if not exists public.smaregi_staff_stores_snapshot (
  contract_id text not null,
  smaregi_staff_id text not null,
  smaregi_store_id text not null,
  run_id uuid,
  fetched_at timestamptz not null default now(),
  primary key (contract_id, smaregi_staff_id, smaregi_store_id)
);
-- 双方向同期の台帳（§11-2。前回同期時点の状態＝3点比較の「前回」）。今回は初期化のためのみ用意し、中身は適用後に作る
create table if not exists public.staff_store_sync (
  user_id uuid not null references public.users(id) on delete cascade,
  contract_id text not null,
  store_id uuid not null references public.stores(id) on delete cascade,
  smaregi_staff_id text,
  smaregi_store_id text,
  last_synced_at timestamptz not null default now(),
  synced_hash text,
  primary key (user_id, contract_id, store_id)
);
alter table public.smaregi_stores_snapshot enable row level security;
alter table public.smaregi_staff_stores_snapshot enable row level security;
alter table public.staff_store_sync enable row level security;
revoke all on public.smaregi_stores_snapshot, public.smaregi_staff_stores_snapshot, public.staff_store_sync from anon, authenticated;

-- 差分（人×店舗）。契約はスナップショットにある契約（今回はトーホーのみ）。
--   対象の人 = employee_profiles.smaregi_staff_id でスマレジと紐付いている人
--   スマレジの事業所 → 店舗 = store_external_mappings(source_system='smaregi_timecard') で変換
create or replace view public.v_staff_store_audit_rows as
with link as (
  select p.user_id, p.smaregi_staff_id from public.employee_profiles p where p.smaregi_staff_id is not null
),
mapped as (
  select e.external_store_id as smaregi_store_id, e.store_id
  from public.store_external_mappings e
  where e.source_system = 'smaregi_timecard' and coalesce(e.is_active, true)
    and (e.effective_to is null or e.effective_to >= current_date)
),
sm as (   -- スマレジ側の所属（管理システムの店舗に変換できたものだけ）
  select l.user_id, m.store_id, s.smaregi_store_id, s.contract_id
  from public.smaregi_staff_stores_snapshot s
  join link l on l.smaregi_staff_id = s.smaregi_staff_id
  join mapped m on m.smaregi_store_id = s.smaregi_store_id
),
mg as (   -- 管理システム側の所属（スマレジと紐付いている人だけ）
  select us.user_id, us.store_id, us.is_primary
  from public.user_stores us join link l on l.user_id = us.user_id
)
select
  coalesce(sm.user_id, mg.user_id) as user_id,
  u.name as user_name,
  coalesce(sm.store_id, mg.store_id) as store_id,
  st.name as store_name,
  case when sm.user_id is not null and mg.user_id is not null then 'keep'
       when sm.user_id is not null then 'add'      -- スマレジにあって管理システムに無い＝追加される
       else 'remove' end as change,                -- 管理システムにあってスマレジに無い＝外される
  mg.is_primary as was_primary
from sm
full join mg on mg.user_id = sm.user_id and mg.store_id = sm.store_id
left join public.users u on u.id = coalesce(sm.user_id, mg.user_id)
left join public.stores st on st.id = coalesce(sm.store_id, mg.store_id);

-- 管理システムに対応が無いスマレジの事業所（隔離対象。その事業所に所属する人の所属は変更しない）
create or replace view public.v_staff_store_audit_unmapped as
select s.contract_id, s.store_id as smaregi_store_id, s.store_code, s.store_name,
       (select count(*) from public.smaregi_staff_stores_snapshot x where x.contract_id = s.contract_id and x.smaregi_store_id = s.store_id) as staff_count
from public.smaregi_stores_snapshot s
where not exists (
  select 1 from public.store_external_mappings e
  where e.source_system = 'smaregi_timecard' and coalesce(e.is_active, true) and e.external_store_id = s.store_id
);

-- スマレジ連携済みなのに、スナップショットに所属が1つも無い人（スマレジ側で退職・所属なし等。置き換えると所属が全部消えるため自動では触らない）
create or replace view public.v_staff_store_audit_nosmaregi as
select p.user_id, u.name as user_name, p.smaregi_staff_id,
       (select count(*) from public.user_stores us where us.user_id = p.user_id) as mgmt_store_count
from public.employee_profiles p
join public.users u on u.id = p.user_id
where p.smaregi_staff_id is not null
  and not exists (select 1 from public.smaregi_staff_stores_snapshot s where s.smaregi_staff_id = p.smaregi_staff_id);

-- スマレジの所属スタッフのうち、管理システムのどの従業員にも紐付いていない人（件数確認用）
create or replace view public.v_staff_store_audit_unlinked as
select s.contract_id, s.smaregi_staff_id, count(*) as store_count
from public.smaregi_staff_stores_snapshot s
where not exists (select 1 from public.employee_profiles p where p.smaregi_staff_id = s.smaregi_staff_id)
group by s.contract_id, s.smaregi_staff_id;

revoke all on public.v_staff_store_audit_rows, public.v_staff_store_audit_unmapped,
  public.v_staff_store_audit_nosmaregi, public.v_staff_store_audit_unlinked from anon, authenticated;
