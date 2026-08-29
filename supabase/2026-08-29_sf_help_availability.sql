-- ============================================================
-- シフト仕上げ A-6: 「ヘルプ」概念の実装（U2）— 担当B
-- 実装指示書_担当B_シフト仕上げと機能追加_2026-08-29.md A-6 参照。
-- 既存テーブル無編集・新規テーブルの追加のみ（sf_接頭辞）。
-- 実行場所: Supabase SQL Editor / Management API（何度実行しても壊れません）
-- ============================================================

-- 「この人はこの日、（自店舗が忙しくなければ）他店舗も含めてヘルプに入れる」という意思表示。
-- 実際にどの店舗をヘルプしたかはsf_shifts側（store_idがヘルプ先）で表現済みのため、
-- ここでは「入れるかどうか」の事前申告だけを持つ（①希望確認・②調整で見る）
create table if not exists sf_help_availability (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  work_date date not null,
  note text,
  created_by uuid references users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, work_date)
);
create index if not exists sf_help_availability_date_idx on sf_help_availability (work_date);

alter table sf_help_availability enable row level security;

-- 閲覧: ログイン済みなら誰でも（他店舗のヘルプ候補を店長・本部が横断的に見られるように。
--   「この日に空いているか」程度の情報で機微性は低いため店舗限定にしていない）
drop policy if exists sfha_read on sf_help_availability;
create policy sfha_read on sf_help_availability for select using (auth.uid() is not null);

-- 書き込み: 本人、またはTENCHO以上の管理者（人手が足りない店舗の店長が、他店舗の人に代理で
--   ヘルプ可否を入れられるようにする＝sf_shiftsの代理入力と同じ考え方）
drop policy if exists sfha_write on sf_help_availability;
create policy sfha_write on sf_help_availability for all using (
  user_id = auth.uid() or exists (
    select 1 from users u where u.id = auth.uid() and u.is_active
      and (u.is_master or u.role in ('CEO','HQ','TEAM','TENCHO'))
  )
) with check (
  user_id = auth.uid() or exists (
    select 1 from users u where u.id = auth.uid() and u.is_active
      and (u.is_master or u.role in ('CEO','HQ','TEAM','TENCHO'))
  )
);
