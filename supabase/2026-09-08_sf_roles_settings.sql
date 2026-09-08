-- 2026-09-08 担当B（nippo）
-- ユーザー指示「シフト管理の情報設計整理：①勤怠を独立メニューに ②シフト内でシフト提出/調整/確定を切替
-- ③実績を5モード切替 ④設定（役割設定を最優先）⑤社員/PA可視化・日別集計 ⑥曜日色 ⑦調整と確定シフトに
-- 店舗/人事シフト切替」のうち、役割設定（最優先指示）とその他の設定項目のDB基盤を追加する。
--
-- 現状、役割（キッチン/ホール/仕込み/ドリンク等）のデータが存在しないため、シフト表で役割別人数
-- （キッチン人数・ホール人数等）を正しく集計できていない、という指摘に対応。

-- ① 店舗ごとの役割マスタ（例: 鳥一代 本店 → キッチン/ホール/仕込み/ドリンク/ランチ）
create table if not exists sf_store_roles (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references stores(id),
  name text not null,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_by uuid references users(id),
  created_at timestamptz not null default now(),
  unique(store_id, name)
);
comment on table sf_store_roles is '店舗ごとに有効な役割の一覧（担当B・nippo所有・2026-09-08新設）。店長以上が設定タブ「役割設定」から編集する';
alter table sf_store_roles enable row level security;
drop policy if exists sf_store_roles_select on sf_store_roles;
create policy sf_store_roles_select on sf_store_roles for select using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active)
);
drop policy if exists sf_store_roles_write on sf_store_roles;
create policy sf_store_roles_write on sf_store_roles for all using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (
    u.is_master or u.role in ('CEO','HQ') or
    ((u.role in ('TENCHO','TEAM')) and store_id = any(
      case when u.role = 'TEAM' then team_store_ids(u.team_id) else user_store_ids(u.id) end
    ))
  ))
) with check (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (
    u.is_master or u.role in ('CEO','HQ') or
    ((u.role in ('TENCHO','TEAM')) and store_id = any(
      case when u.role = 'TEAM' then team_store_ids(u.team_id) else user_store_ids(u.id) end
    ))
  ))
);

-- ② 従業員ごとの主役割・対応可能役割（役割名はsf_store_roles.nameと一致させる想定。店舗をまたぐ
--   ヘルプ勤務等もあるため、あえてsf_store_rolesへの直接FKにはせずテキスト一致で緩く持たせる）
create table if not exists sf_employee_roles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  role_name text not null,
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  unique(user_id, role_name)
);
comment on table sf_employee_roles is '従業員の対応可能役割（is_primary=trueが主役割。担当B・nippo所有・2026-09-08新設）';
alter table sf_employee_roles enable row level security;
drop policy if exists sf_employee_roles_select on sf_employee_roles;
create policy sf_employee_roles_select on sf_employee_roles for select using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active)
);
drop policy if exists sf_employee_roles_write on sf_employee_roles;
create policy sf_employee_roles_write on sf_employee_roles for all using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (
    u.is_master or u.role in ('CEO','HQ','TENCHO','TEAM')
  ))
) with check (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (
    u.is_master or u.role in ('CEO','HQ','TENCHO','TEAM')
  ))
);

-- ③ 各シフトに「その日の勤務役割」を保持（役割別人数集計のキーになる）
alter table sf_shifts add column if not exists role_name text;
comment on column sf_shifts.role_name is 'その日の勤務役割（sf_store_roles.nameのいずれか想定）。役割別人数集計に使用。2026-09-08追加';

-- ④ 店舗ごとの勤怠設定（PA目標人件費率・深夜割増率・ランチ営業有無等をハードコードから設定化）
create table if not exists sf_store_settings (
  store_id uuid primary key references stores(id),
  pa_target_labor_rate numeric not null default 14.0, -- %
  night_premium_rate numeric not null default 1.25, -- 深夜割増率（労基法上の最低は1.25）
  lunch_enabled boolean not null default true,
  sales_basis_rule text not null default 'target' check (sales_basis_rule in ('target','ly','high','avg')),
  updated_by uuid references users(id),
  updated_at timestamptz not null default now()
);
comment on table sf_store_settings is '店舗ごとの勤怠設定（担当B・nippo所有・2026-09-08新設）。未設定の店舗は既存のデフォルト値（PA目標14%・深夜割増1.25・ランチ営業あり）を使う';
alter table sf_store_settings enable row level security;
drop policy if exists sf_store_settings_select on sf_store_settings;
create policy sf_store_settings_select on sf_store_settings for select using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active)
);
drop policy if exists sf_store_settings_write on sf_store_settings;
create policy sf_store_settings_write on sf_store_settings for all using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (
    u.is_master or u.role in ('CEO','HQ') or
    ((u.role in ('TENCHO','TEAM')) and store_id = any(
      case when u.role = 'TEAM' then team_store_ids(u.team_id) else user_store_ids(u.id) end
    ))
  ))
) with check (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (
    u.is_master or u.role in ('CEO','HQ') or
    ((u.role in ('TENCHO','TEAM')) and store_id = any(
      case when u.role = 'TEAM' then team_store_ids(u.team_id) else user_store_ids(u.id) end
    ))
  ))
);
