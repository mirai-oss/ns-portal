-- 会計・請求ワークスペース「自動取込＞未取得」の「▶ 再実行」ボタン用（2026-09-25・ユーザー要望
-- 「失敗したときに、未取得のところからタスクを動かし直せるボタンがあると理想」）。
--
-- 仕組み: ポータル（ブラウザ）は import_run_requests に1行INSERTするだけ。Mac mini の dispatch.js
-- （ns-daily-import/lib/run-requests.js）が数分おきに status='pending' を拾って `node run.js <job>` を
-- 実行し、結果を同じ行へ書き戻す（service_keyで更新するためUPDATEのRLSポリシーは不要）。
-- ブラウザにGASトークン等の秘密情報を置かずに済ませるため、この形にしている。
--
-- 【安全策】
--  * INSERT できるのは「有効なマスター／CEO／HQ」だけ（既存のRLSと同じ判定）。
--  * 対象ジョブは import_schedule の「月次・有効・kind∈deposit/purchase/sales」に限定
--    （＝自動取込タブの未取得に出るジョブだけ。任意のジョブは依頼できない）。
--  * 同一ジョブの pending/running が残っている間は重複依頼を弾く（部分ユニークインデックス）。
--  * Mac mini側でも同じ条件を再チェックしてから実行する（二重防御）。
--
-- 【影響】新規テーブル追加のみ。既存テーブル・ジョブのロジックは変更しない。
-- 【rollback】 drop table if exists public.import_run_requests;

create table if not exists public.import_run_requests (
  id uuid primary key default gen_random_uuid(),
  job text not null,                          -- import_schedule.job（例 paypay-merchant-deposit）
  target_ym text,                             -- 任意。'YYYY-MM'（省略時は各ジョブの既定＝前月等）
  requested_by uuid default auth.uid(),
  requested_at timestamptz not null default now(),
  status text not null default 'pending',     -- pending / running / success / partial / failed
  started_at timestamptz,
  finished_at timestamptz,
  result text                                 -- 実行結果の要約（Mac miniが書き戻す）
);

create index if not exists import_run_requests_status_idx on public.import_run_requests (status, requested_at);
create index if not exists import_run_requests_job_idx on public.import_run_requests (job, requested_at desc);
create unique index if not exists import_run_requests_one_open_per_job
  on public.import_run_requests (job) where status in ('pending', 'running');

alter table public.import_run_requests enable row level security;

drop policy if exists import_run_requests_select_authenticated on public.import_run_requests;
create policy import_run_requests_select_authenticated on public.import_run_requests
  for select to authenticated using (true);

drop policy if exists import_run_requests_insert_hq on public.import_run_requests;
create policy import_run_requests_insert_hq on public.import_run_requests
  for insert to authenticated
  with check (
    status = 'pending'
    and requested_by = auth.uid()
    and exists (
      select 1 from public.users u
      where u.id = auth.uid() and u.is_active and (u.is_master or u.role in ('CEO', 'HQ'))
    )
    and job in (
      select s.job from public.import_schedule s
      where s.active and s.frequency = 'monthly' and s.kind in ('deposit', 'purchase', 'sales')
    )
  );
