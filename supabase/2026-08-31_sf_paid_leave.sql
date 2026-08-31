-- 2026-08-31 担当B（nippo）B-17
-- 有給申請機能（実装指示書_ラウンド5_2026-08-31.md §2 B-17／設計確定は同§2.1）。
-- B-16調査の結果、スマレジAPIの有給残数フィールドは値が信用できなかった（全員0）ため、
-- 手入力の付与実績台帳（sf_paid_leave_grants）から残日数を計算する方式にする。
-- 残日数 = SUM(sf_paid_leave_grants.granted_days) - SUM(承認済みsf_paid_leave_requests.days)

-- 付与実績（入社時・年次付与などをマスター/HQが都度追加する台帳。1行=1回の付与）
create table if not exists sf_paid_leave_grants (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  granted_days numeric not null,
  granted_on date not null default current_date,
  note text,
  created_by uuid references users(id),
  created_at timestamptz not null default now()
);
comment on table sf_paid_leave_grants is '有給の付与実績台帳（手入力）。2026-08-31追加（B-17）。スマレジAPIの残数フィールドが信用できないため、こちらを正本にする';

alter table sf_paid_leave_grants enable row level security;
create policy sf_paid_leave_grants_read on sf_paid_leave_grants for select using (
  auth.uid() = user_id
  or exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ','TEAM','TENCHO')))
);
create policy sf_paid_leave_grants_write on sf_paid_leave_grants for all using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
) with check (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ')))
);

-- 申請（本人が申請→チーム長/本部/社長/マスターの誰かが承認）
create table if not exists sf_paid_leave_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  store_id uuid references stores(id),
  date_from date not null,
  date_to date not null,
  days numeric not null check (days > 0), -- 半休は0.5を許容
  reason text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  approved_by uuid references users(id),
  approved_at timestamptz,
  reject_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table sf_paid_leave_requests is '有給申請。2026-08-31追加（B-17）。本人申請→チーム長/本部/社長/マスターが承認';

alter table sf_paid_leave_requests enable row level security;
-- 読み取り: 本人、または承認できる立場の人（チーム長/本部/社長/マスター）
create policy sf_paid_leave_requests_read on sf_paid_leave_requests for select using (
  auth.uid() = user_id
  or exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ','TEAM','TENCHO')))
);
-- 申請の新規作成: 本人のみ（他人になりすまして申請できないようにする）
create policy sf_paid_leave_requests_insert on sf_paid_leave_requests for insert with check (
  auth.uid() = user_id
);
-- 更新①: 本人は自分の「未承認(pending)」申請を取り下げ（status→rejected）できるだけ。
--   承認済みになりすまして自分で承認することはできないようガードする
create policy sf_paid_leave_requests_update_self on sf_paid_leave_requests for update using (
  auth.uid() = user_id and status = 'pending'
) with check (
  auth.uid() = user_id and status = 'rejected' and approved_by is null
);
-- 更新②: 承認できる立場の人（チーム長/本部/社長/マスター）は承認・却下のため全項目を更新可
create policy sf_paid_leave_requests_update_approver on sf_paid_leave_requests for update using (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ','TEAM','TENCHO')))
) with check (
  exists(select 1 from users u where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO','HQ','TEAM','TENCHO')))
);
