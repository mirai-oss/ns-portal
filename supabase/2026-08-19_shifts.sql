-- ============================================================
-- シフト（機能④）— 要件定義書v3.2 §9・§19／docs/シフト打刻_設計書.md v1.0
-- 画面=日報システム（現場アプリ）／データ=ハブ。sf_接頭辞で新設（既存テーブル無変更）。
-- 対象者=AL/SHAIN/TENCHO/TEAM以上の全員。提出=月2回（10日/25日公開・5日前締切）。
-- 打刻（⑤）は別フェーズ。冪等。
-- ============================================================

-- 管理権限: マスター/CEO/HQ/TEAMは全店舗、TENCHOは自店舗のみ
create or replace function sf_can_manage(p_store_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case
      when u.is_master or u.role in ('CEO','HQ','TEAM') then true
      when u.role = 'TENCHO' then exists(
        select 1 from user_stores us where us.user_id = u.id and us.store_id = p_store_id
      )
      else false
    end
    from users u where u.id = auth.uid() and u.is_active
  ), false);
$$;

-- 店舗ごとの時間帯プリセット（例: ランチ/ディナー/終日。店長が管理画面から入力）
create table if not exists sf_time_presets (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references stores(id) on delete cascade,
  label text not null,
  start_time time not null,
  end_time time not null,
  break_minutes int not null default 0,
  sort_order int not null default 100,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists sf_time_presets_store_idx on sf_time_presets (store_id, sort_order);

-- シフト本体（1人・1日・1エントリ）
create table if not exists sf_shifts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  store_id uuid not null references stores(id) on delete cascade,
  work_date date not null,
  start_time time not null,
  end_time time not null,
  break_minutes int not null default 0,
  preset_id uuid references sf_time_presets(id) on delete set null,
  is_off boolean not null default false,           -- 休み希望（時間は無視）
  period_key text not null,                        -- 例 '2026-09-A'(1-15日) '2026-09-B'(16-末日)
  status text not null default 'draft' check (status in ('draft','submitted','published','cancelled')),
  submitted_at timestamptz,
  published_at timestamptz,
  smaregi_shift_result_id text,
  smaregi_sync_status text not null default 'pending' check (smaregi_sync_status in ('pending','synced','error')),
  smaregi_error text,
  created_by uuid references users(id) on delete set null,  -- 本人 or 代理入力した店長/本部
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, work_date)
);
create index if not exists sf_shifts_store_date_idx on sf_shifts (store_id, work_date);
create index if not exists sf_shifts_period_idx on sf_shifts (period_key, store_id);
create index if not exists sf_shifts_user_idx on sf_shifts (user_id, period_key);

-- 必要人数（初回は未入力運用。店舗×曜日 or 店舗×特定日で上書き）
create table if not exists sf_required_headcounts (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references stores(id) on delete cascade,
  preset_id uuid references sf_time_presets(id) on delete cascade,
  weekday int check (weekday between 0 and 6),
  specific_date date,
  required_count int not null check (required_count >= 0),
  created_at timestamptz not null default now()
);
create index if not exists sf_required_headcounts_store_idx on sf_required_headcounts (store_id);

alter table sf_time_presets enable row level security;
alter table sf_shifts enable row level security;
alter table sf_required_headcounts enable row level security;

-- 時間帯プリセット: 閲覧=全員、編集=sf_can_manage(store_id)
drop policy if exists sftp_read on sf_time_presets;
create policy sftp_read on sf_time_presets for select using (auth.uid() is not null);
drop policy if exists sftp_write on sf_time_presets;
create policy sftp_write on sf_time_presets for all
  using (sf_can_manage(store_id)) with check (sf_can_manage(store_id));

-- シフト: 閲覧=本人／所属店舗の同僚／管理者。作成=本人 or 管理者（代理入力）。
-- 更新・削除=本人（未公開のみ）or 管理者（公開後含め常に）
drop policy if exists sfs_read on sf_shifts;
create policy sfs_read on sf_shifts for select using (
  auth.uid() is not null and (
    user_id = auth.uid()
    or sf_can_manage(store_id)
    or exists(select 1 from user_stores us where us.user_id = auth.uid() and us.store_id = sf_shifts.store_id)
  )
);
drop policy if exists sfs_insert on sf_shifts;
create policy sfs_insert on sf_shifts for insert with check (
  (user_id = auth.uid() or sf_can_manage(store_id))
);
drop policy if exists sfs_update on sf_shifts;
create policy sfs_update on sf_shifts for update using (
  (user_id = auth.uid() and status <> 'published') or sf_can_manage(store_id)
) with check (
  (user_id = auth.uid() and status <> 'published') or sf_can_manage(store_id)
);
drop policy if exists sfs_delete on sf_shifts;
create policy sfs_delete on sf_shifts for delete using (
  (user_id = auth.uid() and status = 'draft') or sf_can_manage(store_id)
);

-- 必要人数: 閲覧=全員、編集=sf_can_manage(store_id)
drop policy if exists sfrh_read on sf_required_headcounts;
create policy sfrh_read on sf_required_headcounts for select using (auth.uid() is not null);
drop policy if exists sfrh_write on sf_required_headcounts;
create policy sfrh_write on sf_required_headcounts for all
  using (sf_can_manage(store_id)) with check (sf_can_manage(store_id));
