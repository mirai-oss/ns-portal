-- 会計・請求ワークスペースUI刷新（実装指示書_会計請求ワークスペースUI刷新_2026-09-11.md §9-10/11）
-- 担当D「自動取込の実体」分: Playwright/API取込ジョブ（ns-daily-import）の実行履歴をDBへ記録する。
--
-- 【背景・現状の課題】ns-daily-import の13ジョブ（PayPay銀行・インフォマート・スマレジ等）は現在、
-- 実行結果を Mac mini ローカルの logs/*.log とマーカーファイルにしか残しておらず、DBには一切記録が無い
-- （ai-agent-team/import_task_board.md に明記: 「『前回』列は本Macからは確認できません」）。
-- そのため会計・請求ワークスペースの「自動取込」タブ（内部タブ=手動アップロード/自動取込/未取得/取込履歴）
-- が参照できるデータが存在しない。本migrationはこの欠落を埋める。
--
-- 【影響】新規テーブル追加のみ。既存テーブル・既存ジョブのロジックは変更しない
-- （書き込みは ns-daily-import/run.js から新たに追加するのみ・失敗してもジョブ本体は止めない設計）。
--
-- 【rollback】 drop view if exists public.import_status_today;
--              drop table if exists public.import_runs;
--              drop table if exists public.import_schedule;
--              drop table if exists public.import_paypay_settlement;

-- ── 1) import_runs: 実行履歴（事実テーブル）。取込ジョブ1回の実行=1行 ──
create table if not exists public.import_runs (
  id uuid primary key default gen_random_uuid(),
  job text not null,                              -- タスクキー（例: paypay-bank）。import_task_board.mdの#と対応
  source text not null default 'playwright',       -- playwright/api/reconcile/manual/email/zip
  kind text,                                       -- deposit/purchase/attendance/media/orders/questionnaire/reservation/sales/other
  target_ym text,                                  -- 対象年月がわかる場合のみ（例 '2026-09'）
  host text,                                       -- 実行機（mac-mini/macbook等。env NS_HOSTで指定。未設定なら null）
  triggered_by text not null default 'schedule',   -- schedule(dispatch.js)/queue(スマホ依頼)/lark/manual
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running',          -- running/success/partial/failed
  duration_sec integer,
  detail text,                                     -- task.run()のresult.detail等（人が読む要約）
  error text,
  items jsonb,                                     -- 任意の内訳（例: PayPayの店舗別件数・金額）
  created_at timestamptz not null default now()
);
create index if not exists import_runs_job_started_idx on public.import_runs (job, started_at desc);
alter table public.import_runs enable row level security;
drop policy if exists import_runs_select_authenticated on public.import_runs;
create policy import_runs_select_authenticated on public.import_runs for select to authenticated using (true);

-- ── 2) import_schedule: D管轄ジョブの予定表（import_task_board.mdのDB版）。「未取得」判定の基準。 ──
-- 注意: 担当C側の ar_recurring_master（請求書/売上入金全般の定期マスタ・取引先/頻度/自動化レベル等）
-- とは別テーブル（こちらはPlaywright/APIジョブ固有の実行スケジュールのみを持つ、より軽量なもの）。
-- job/kindのキーは揃えてあるので、将来 ar_recurring_master 側からこのjobキーで参照可能。
create table if not exists public.import_schedule (
  job text primary key,
  label text not null,
  source text not null default 'playwright',
  kind text,
  frequency text not null default 'daily',   -- daily/monthly/independent
  expected_time_jst text,                    -- 'HH:MM'
  monthly_days int[],                        -- 月次の場合の実行日（例 {1,15}）
  grace_minutes int not null default 180,    -- 予定時刻からこの分を超えて当日成功が無ければ「未取得」
  active boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.import_schedule enable row level security;
drop policy if exists import_schedule_select_authenticated on public.import_schedule;
create policy import_schedule_select_authenticated on public.import_schedule for select to authenticated using (true);

insert into public.import_schedule (job, label, source, kind, frequency, expected_time_jst, monthly_days, grace_minutes) values
  ('zeroregi-akihabara',   'ZeroRegi売上(秋葉原)',   'playwright', 'sales',         'daily',   '06:30', null,        180),
  ('infomart-siire',       'インフォマート仕入れ',     'playwright', 'purchase',      'daily',   '06:45', null,        180),
  ('smaregi-payroll',      'スマレジ人件費',          'playwright', 'attendance',    'daily',   '07:00', null,        180),
  ('dinii-media',          'Dinii媒体別',            'playwright', 'media',         'daily',   '07:30', null,        180),
  ('dinii-orders',         'Dinii注文明細',           'playwright', 'orders',        'daily',   '07:35', null,        180),
  ('dinii-questionnaire',  'Diniiアンケート',         'playwright', 'questionnaire', 'daily',   '07:45', null,        180),
  ('dinii-payment-ns',     'Dinii支払い(NS)',        'playwright', 'deposit',       'daily',   '08:00', null,        180),
  ('dinii-payment-nstyle', 'Dinii支払い(N-Style)',   'playwright', 'deposit',       'daily',   '08:30', null,        180),
  ('arena-events',         '横浜アリーナ イベント',     'playwright', 'other',         'monthly', '08:40', '{1,15}',   1440),
  ('nissan-stadium-events','日産スタジアム イベント',   'playwright', 'other',         'monthly', '08:45', '{1,15}',   1440),
  ('paypay-bank',          'PayPay入金(NS)',         'playwright', 'deposit',       'daily',   '13:00', null,        180),
  ('paypay-bank-b',        'PayPay入金(NS-B)',       'playwright', 'deposit',       'daily',   '13:15', null,        180),
  ('bq-sales-reconcile',   '売上BQミラー突合',        'reconcile',  'sales',         'daily',   '11:00', null,        180)
on conflict (job) do update set
  label=excluded.label, source=excluded.source, kind=excluded.kind, frequency=excluded.frequency,
  expected_time_jst=excluded.expected_time_jst, monthly_days=excluded.monthly_days,
  grace_minutes=excluded.grace_minutes, updated_at=now();

-- ── 3) import_status_today: 「今日この瞬間」のジョブ状態ビュー（自動取込タブの一覧・未取得タブ用） ──
create or replace view public.import_status_today as
select
  s.job, s.label, s.source, s.kind, s.frequency, s.expected_time_jst, s.monthly_days, s.grace_minutes,
  lr.id as last_run_id, lr.started_at as last_started_at, lr.finished_at as last_finished_at,
  lr.status as last_status, lr.error as last_error, lr.duration_sec as last_duration_sec,
  ta.attempts_today, ta.success_today,
  case
    when s.frequency = 'monthly'
      and not (extract(day from (now() at time zone 'Asia/Tokyo'))::int = any(coalesce(s.monthly_days, array[]::int[])))
      then false
    when s.expected_time_jst is null then false
    else (
      (now() at time zone 'Asia/Tokyo') >
        (((now() at time zone 'Asia/Tokyo')::date)::timestamp + s.expected_time_jst::time + (s.grace_minutes || ' minutes')::interval)
      and not coalesce(ta.success_today, false)
    )
  end as is_overdue
from public.import_schedule s
left join lateral (
  select * from public.import_runs r
  where r.job = s.job
  order by r.started_at desc
  limit 1
) lr on true
left join lateral (
  select
    count(*) as attempts_today,
    bool_or(r2.status = 'success') as success_today
  from public.import_runs r2
  where r2.job = s.job
    and (r2.started_at at time zone 'Asia/Tokyo')::date = (now() at time zone 'Asia/Tokyo')::date
) ta on true
where s.active;

-- ── 4) import_paypay_settlement: PayPay等QR決済の店舗別精算集計（§9-9） ──
-- 【現状】データ投入元（PayPay加盟店ポータルの新規Playwright取得／メール添付の精算書等）は未確定のため
-- このテーブルはまだ空（未実装）。司令塔・担当Cと投入方法を確定してから取込を実装する（WORKLOG参照）。
-- store_id=null は「店舗を特定できない月額利用料・共通システム料」＝is_common_cost=trueの行として、
-- AIによる店舗按分を行わずそのまま「共通費」で保持する（§9-9の明示指示）。
create table if not exists public.import_paypay_settlement (
  id uuid primary key default gen_random_uuid(),
  store_id uuid references public.stores(id),   -- null=店舗特定不能（共通費）
  is_common_cost boolean not null default false,
  target_ym text not null,                       -- 'YYYY-MM'
  transaction_amount numeric,                    -- 取引金額
  system_fee numeric,                            -- システム利用料
  deposit_amount numeric,                        -- 入金相当額（=取引金額-システム利用料が原則）
  source_run_id uuid references public.import_runs(id),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists import_paypay_settlement_store_ym_idx on public.import_paypay_settlement (store_id, target_ym);
alter table public.import_paypay_settlement enable row level security;
drop policy if exists import_paypay_settlement_select_authenticated on public.import_paypay_settlement;
create policy import_paypay_settlement_select_authenticated on public.import_paypay_settlement for select to authenticated using (true);
