-- 店舗×MF事業者ごとの部門名（黒霧屋 新横浜の運営変更 2026-11-01）
-- 店舗マスタの stores.mf_department_name は1つ（=トーホーのMFの部門名）。運営会社が変わるとLiveGateのMFの部門に仕訳を作るが、
-- LiveGateのMFの部門名は別（例: 「08（タブ）黒霧屋 新横浜」）。事業者(tenant_id)ごとに部門名を持てるようにする。
-- 該当行が無い事業者は、従来どおり stores.mf_department_name を使う（他の店舗・事業者への影響なし）。
create table if not exists public.store_tenant_departments (
  store_id uuid not null references public.stores(id),
  tenant_id text not null,
  department_name text not null,    -- MFの部門名そのまま（空白・タブも含めて完全一致）
  note text,
  updated_at timestamptz not null default now(),
  primary key (store_id, tenant_id)
);
alter table public.store_tenant_departments enable row level security;
drop policy if exists store_tenant_departments_all_inv on public.store_tenant_departments;
create policy store_tenant_departments_all_inv on public.store_tenant_departments for all using (invoice_can_access()) with check (invoice_can_access());

insert into public.store_tenant_departments (store_id, tenant_id, department_name, note)
select s.id, 'livegate', E'08\t黒霧屋 新横浜', 'LiveGateのMFの部門（2026-10-17確認。名前の「08」と「黒霧屋」の間はタブ文字）'
from public.stores s where s.name = '黒霧屋 新横浜'
on conflict (store_id, tenant_id) do update set department_name = excluded.department_name, updated_at = now();
