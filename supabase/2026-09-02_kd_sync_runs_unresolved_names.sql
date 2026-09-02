-- W2①（設計書_表示集計層kdと高速化実行計画_2026-09-02.md §3/§4/§10.1・レーンP所有）
-- kd_sync_runs: kd_サマリ系リフレッシュ実行台帳。画面はsync_run_id（または該当jobのfinished_at）が
--   変わった時だけ再取得する＝キャッシュ無効化の正本（§7）。
-- kd_unresolved_names: store_aliases等の正式名に無い名前を隔離するテーブル（原則5の強化）。
--   ns-daily-import等の取込ジョブはservice roleでkd_report_unresolved_name()をRPC呼び出しして登録する
--   （直接INSERTだとoccurrences/last_seenの更新ロジックが重複するため関数化）。

create table if not exists public.kd_sync_runs (
  id uuid primary key default gen_random_uuid(),
  job text not null,                    -- 'kd_reservation_daily_summary'|'kd_dashboard_daily_summary'|'kd_home_kpi_snapshot'等
  period_from date,
  period_to date,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running', 'success', 'failed')),
  rows int,
  error text,
  created_at timestamptz not null default now()
);
create index if not exists kd_sync_runs_job_started_idx on public.kd_sync_runs (job, started_at desc);

alter table public.kd_sync_runs enable row level security;
drop policy if exists kd_sync_runs_select_authenticated on public.kd_sync_runs;
-- 読み取りは全ログインユーザーに許可（sync_run_idの変化だけを見る用途で機微情報を含まないため）。
-- 書き込みはservice_role（各kd_リフレッシュジョブ）のみ＝ポリシー無しで自動的に拒否される。
create policy kd_sync_runs_select_authenticated on public.kd_sync_runs
  for select to authenticated using (true);

create table if not exists public.kd_unresolved_names (
  id uuid primary key default gen_random_uuid(),
  source_table text not null,     -- 取込元テーブル/ジョブ名（例: 'rsv_reservations','stg_deposit'）
  kind text not null check (kind in ('store', 'media')),
  raw_name text not null,
  payload jsonb not null default '{}'::jsonb,   -- 取込ジョブ側の追加情報（例: 対象月・元ファイル名）
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  occurrences int not null default 1,
  status text not null default 'open' check (status in ('open', 'resolved')),
  resolved_at timestamptz,
  resolved_by uuid references public.users (id)
);
create unique index if not exists kd_unresolved_names_unique on public.kd_unresolved_names (source_table, kind, raw_name);
create index if not exists kd_unresolved_names_status_idx on public.kd_unresolved_names (status, last_seen desc);

alter table public.kd_unresolved_names enable row level security;
drop policy if exists kd_unresolved_names_select_admin on public.kd_unresolved_names;
-- 未解決名の一覧はCEO/HQ/マスターのみ閲覧可（現場の取込ジョブはservice_roleでRPC経由で書くためRLS対象外）
create policy kd_unresolved_names_select_admin on public.kd_unresolved_names
  for select to authenticated using (
    exists (
      select 1 from public.users u
      where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO', 'HQ'))
    )
  );

-- 取込ジョブ側からの登録用RPC（service_role専用）。
-- 既存名なら occurrences+1・last_seen更新（resolved済みなら再びopenへ戻す＝新しい表記ゆれが直った後で
-- また出た場合に気付けるようにする）。新規名ならinsert。
create or replace function public.kd_report_unresolved_name(
  p_source_table text, p_kind text, p_raw_name text, p_payload jsonb default '{}'::jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.kd_unresolved_names (source_table, kind, raw_name, payload, occurrences)
  values (p_source_table, p_kind, p_raw_name, coalesce(p_payload, '{}'::jsonb), 1)
  on conflict (source_table, kind, raw_name) do update
    set occurrences = kd_unresolved_names.occurrences + 1,
        last_seen = now(),
        payload = coalesce(excluded.payload, kd_unresolved_names.payload),
        status = 'open'; -- 解決済みでも再出現したら再度openへ（表記ゆれの再発に気付けるように）
end;
$$;
revoke all on function public.kd_report_unresolved_name(text, text, text, jsonb) from public;
grant execute on function public.kd_report_unresolved_name(text, text, text, jsonb) to service_role;

-- 解決マーク用RPC（管理画面/手動運用から。CEO/HQ/マスターのみ）
create or replace function public.kd_resolve_unresolved_name(p_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.users u
    where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO', 'HQ'))
  ) then
    raise exception '権限がありません（CEO/HQ/マスターのみ）';
  end if;
  update public.kd_unresolved_names set status = 'resolved', resolved_at = now(), resolved_by = auth.uid()
  where id = p_id;
end;
$$;
revoke all on function public.kd_resolve_unresolved_name(uuid) from public;
grant execute on function public.kd_resolve_unresolved_name(uuid) to authenticated;
