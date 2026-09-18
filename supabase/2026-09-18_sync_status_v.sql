-- TK-66（sync_status見える化）。担当D。
--
-- 【理由】これまで「データが最新か」を確認する手段が、①kd_サマリの更新状況(kd_sync_status_v・
-- レーンP管轄)②生データ取込の実行状況(import_runs・担当D管轄)の2つに分かれていて、どちらか
-- 一方しか見ていない画面・ツールが多かった（例: 担当Dのmorning-watchdogはimport_runsだけ、
-- tori-dashboardのdataFreshnessはkd_sync_status_vだけ）。どちらも「最新のジョブ実行1件」を
-- 返すだけの軽い作りなので、1つのビューに統合して「システム全体の同期状態」を1回のPostgREST
-- 読み取り（GAS/BQ経由なし）で確認できるようにする。
--
-- 【現在の構造】
--   kd_sync_status_v = kd_sync_runs（レーンPのkd_サマリ更新ログ）のジョブ別最新1件
--   import_runs      = ns-daily-import各ジョブ（担当D管轄・PayPay/dinii/ロケットナウ等）の実行ログ
--
-- 【影響】新規ビューの追加のみ。既存テーブル・既存ビューは無変更（kd_sync_status_vの定義もそのまま）。
-- 【rollback】 drop view if exists public.sync_status_v;

create or replace view public.sync_status_v as
select
  'kd_refresh'::text as category,          -- kd_サマリの更新ジョブ（レーンP管轄）
  job,
  period_from::text as period_from,
  period_to::text as period_to,
  started_at,
  finished_at,
  status,
  rows,
  error
from public.kd_sync_status_v
union all
select
  'ingest'::text as category,              -- 生データ取込ジョブ（担当D管轄・ns-daily-import）
  job,
  target_ym as period_from,
  target_ym as period_to,
  started_at,
  finished_at,
  status,
  null::integer as rows,
  error
from (
  select distinct on (job)
    job, target_ym, started_at, finished_at, status, error
  from public.import_runs
  order by job, started_at desc
) t;

comment on view public.sync_status_v is
  'TK-66: kd_サマリ更新(kd_sync_status_v)と生データ取込(import_runs)のジョブ別最新実行状況を1つに統合。categoryで種別を区別。画面・監視ツールはこれ1本を読めば「何が・いつ・成功したか」が分かる（GAS/BQ経由なし・PostgREST直読み）。';
