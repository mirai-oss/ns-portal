-- 【実行済み・再実行しない】所属店舗の初回一致（スマレジ・タイムカードを正本）の適用（担当D・2026-10-17・司令塔GO）
-- 設計: docs/設計メモ_スマレジ複数契約対応_2026-10-15.md §11-4／§11-5。対象=26人（追加35行・外す13行）。
--   スマレジに店舗所属の無い9人・未紐付けの3人は変更しない（差分ビューが除外済み）。
-- 手順: ①user_storesをバックアップ表へ退避 ②差分ビュー(v_staff_store_audit_rows)どおりに追加・削除 ③主たる店舗が外れた人の主たる店舗を決定
--   （残る所属が1つ→それ／複数→直近30日の勤怠が最も多い店舗／勤怠なし→sort_orderの先頭）④同期台帳staff_store_syncを初期化（両側で一致している人×店舗）
-- rollback: user_stores_backup_20261017 から戻す（delete from user_stores where user_id in (対象26人); insert into user_stores select * from user_stores_backup_20261017 where user_id in (対象26人);）
begin;
create table public.user_stores_backup_20261017 as select * from public.user_stores;
revoke all on public.user_stores_backup_20261017 from anon, authenticated;
alter table public.user_stores_backup_20261017 enable row level security;

create temp table _plan on commit drop as
  select user_id, store_id, change from public.v_staff_store_audit_rows where change in ('add', 'remove');

delete from public.user_stores us using _plan p
  where p.change = 'remove' and us.user_id = p.user_id and us.store_id = p.store_id;
insert into public.user_stores (user_id, store_id, is_primary)
  select user_id, store_id, false from _plan where change = 'add' on conflict do nothing;

-- 主たる店舗が無くなった人（今回の削除で外れた人）の主たる店舗を決める
with np as (
  select distinct p.user_id from _plan p
  where not exists (select 1 from public.user_stores x where x.user_id = p.user_id and x.is_primary)
),
cand as (
  select us.user_id, us.store_id,
    coalesce((select count(*) from public.attendance_records a
              where a.user_id = us.user_id and a.store_id = us.store_id and a.work_date >= current_date - 30), 0) as att,
    st.sort_order
  from public.user_stores us join public.stores st on st.id = us.store_id
  where us.user_id in (select user_id from np)
),
pick as (select distinct on (user_id) user_id, store_id from cand order by user_id, att desc, sort_order)
update public.user_stores us set is_primary = true from pick
  where us.user_id = pick.user_id and us.store_id = pick.store_id;

-- 同期台帳の初期化（両側で一致している 人×店舗）
insert into public.staff_store_sync (user_id, contract_id, store_id, smaregi_staff_id, smaregi_store_id, last_synced_at, synced_hash)
select us.user_id, s.contract_id, us.store_id, p.smaregi_staff_id, s.smaregi_store_id, now(), md5(us.user_id::text || us.store_id::text)
from public.user_stores us
join public.employee_profiles p on p.user_id = us.user_id and p.smaregi_staff_id is not null
join public.smaregi_staff_stores_snapshot s on s.smaregi_staff_id = p.smaregi_staff_id
join public.store_external_mappings m on m.source_system = 'smaregi_timecard' and m.external_store_id = s.smaregi_store_id
  and m.store_id = us.store_id and coalesce(m.is_active, true)
on conflict do nothing;
commit;
