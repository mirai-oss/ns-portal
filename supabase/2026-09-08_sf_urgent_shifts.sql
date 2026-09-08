-- 2026-09-08 担当B（nippo）
-- ユーザー指示「完成HTML(NStyle_シフト管理_UI_v12)のDOM・CSS・文言をそのまま移植し、
-- 急募（現在の急募・急募対応TOP・不足枠を急募）等の要素も含めて機能を接続してほしい」に対応。
-- 急募機能はこれまでnippoに存在しなかったため、最小限の実データテーブルを新設する
-- （LINE通知・応募受付・自動採用までは今回のスコープ外。まずは「掲示」と「手動で確定」までを提供）。

create table if not exists sf_urgent_shifts (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references stores(id),
  work_date date not null,
  start_time text,
  end_time text,
  role_label text,
  headcount integer not null default 1,
  message text,
  status text not null default 'open' check (status in ('open','filled','cancelled')),
  created_by uuid references users(id),
  filled_by uuid references users(id),
  filled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table sf_urgent_shifts is '急募シフトの掲示（担当B・nippo所有。2026-09-08新設）。LINE通知・応募受付は未実装で、店長以上が掲示・手動確定するところまでを提供';

alter table sf_urgent_shifts enable row level security;
drop policy if exists sf_urgent_shifts_rw on sf_urgent_shifts;
create policy sf_urgent_shifts_rw on sf_urgent_shifts for all using (
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
