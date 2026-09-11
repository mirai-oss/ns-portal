-- 2026-09-11: 「売上入金」新規テーブル群（担当C・接頭辞ar_・invoices名前空間の拡張）
-- 実装指示書_会計請求ワークスペースUI刷新_2026-09-11.md Step4（会計・請求ワークスペースの
-- 「売上入金」タブ）に対応。§9-20の事前報告様式に沿って、この冒頭コメントに
-- 「なぜ必要か／現在の構造／既存データへの影響／migration／rollback／既存機能への影響」
-- をまとめてから実行する（新規テーブルのみ・既存テーブルへの変更は一切無いため実害はゼロ）。
--
-- 【なぜ必要か】
-- 指示書§9-8「売上入金は請求書と別管理。フロー=売上発生→入金予定→実入金→照合→消込」に
-- 対応する実データが、現行invoices.html・DBのどこにも存在しない（invoicesテーブルは
-- 支払う側=請求書の管理のみ）。§9-9（PayPay決済店舗別集計）もこの新テーブル群が受け皿になる。
--
-- 【現在の構造・関連テーブル】
-- 担当D（自動取込レーン・ns-daily-import）が本指示書§1担当D分として先行して以下を新設済み
-- （2026-09-11・コミット参照：import_runs基盤のWORKLOGエントリ）:
--   - import_schedule: 定期取込ジョブの定義（job/label/source/kind/frequency/
--     expected_time_jst/monthly_days等）。現在paypay-bank/paypay-bank-b等13ジョブ登録済み
--     （kind='deposit'のPayPay分はいずれも「銀行口座のATM入金明細」取込で、本テーブル群が
--     必要とする「PayPay決済の加盟店手数料明細」とは別データ。ユーザー確認により加盟店明細は
--     「PayPay for Business管理画面」から取得する新規Playwrightジョブが別途必要と判明
--     ＝WORKLOG参照。担当D側の対応待ち）
--   - import_runs: 取込ジョブの実行ログ（自動取込タブの「取込履歴」のデータ源になる）
--   - import_paypay_settlement: PayPay決済明細の格納先（store_id・is_common_cost・
--     target_ym・transaction_amount・system_fee・deposit_amount・source_run_id）。
--     新規Playwrightジョブが実装されればここにデータが入る設計で準備済み（現状0件）
-- 本マイグレーションは、この「取込済みの生データ（import_paypay_settlement等、取込元ごとに
-- 形が違う）」を、会計・消込処理で扱いやすい「取込元を問わない共通形」に正規化する層として
-- ar_receivables/ar_deposits/ar_matchingを新設する（kd_実行計画の原則どおりID正本・
-- store_name列を作らない）。ar_recurring_masterは、import_scheduleが持たない会計・自動化
-- 観点の項目（自動化レベルLv1〜4・担当者・請求書or売上入金の別）を管理する（import_schedule
-- とはjob名（テキスト）で緩く対応付けるだけで、外部キー制約は張らない＝担当D側テーブルを
-- 直接編集・参照制約しない。自動取込ジョブが無い手動運用の定期項目も登録できるようにするため）
--
-- 【既存データへの影響】無し（全て新規テーブル。既存テーブルへのALTERは無い）
-- 【migration】このファイル自体（CREATE TABLEのみ・冪等）
-- 【rollback】各テーブルをDROPすれば良い（他テーブルから参照されない新規名前空間のため、
-- 依存関係の心配は無い）: drop table if exists ar_matching, ar_deposits, ar_receivables,
-- ar_recurring_master;
-- 【既存機能への影響】無し（新規タブ「売上入金」専用。invoices.html他タブ・他システムは
-- このテーブル群を一切参照していない）

-- ① 定期請求・入金マスタ（指示書§9-11）
create table if not exists ar_recurring_master (
  id uuid primary key default gen_random_uuid(),
  name text not null,                                   -- 取引先・入金元の表示名（例: PayPay・SUUMO）
  kind text not null check (kind in ('invoice','receivable')), -- 請求書 or 売上入金のどちらの定期項目か
  import_job text,                                       -- import_schedule.jobとの緩い対応（自動取込ジョブが無ければnull）
  frequency text,                                        -- 例: monthly
  expected_day_from int,                                 -- 通常取得日（範囲の開始。単日なら同じ値）
  expected_day_to int,
  fetch_method text,                                      -- playwright/email/api/manual
  automation_level int check (automation_level between 1 and 4), -- Lv1取得のみ〜Lv4完全自動
  owner_user_id uuid references users(id),
  is_active boolean not null default true,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table ar_recurring_master is
  '定期請求・入金マスタ（会計・請求ワークスペースUI刷新Step4・指示書§9-11）。
   import_schedule（担当D管轄・自動取込の実体）とはimport_job列で緩く対応付けるのみ。
   自動化レベル・担当者・請求書/売上入金の別など会計側の管理項目を持つ。';

-- ② 売上入金予定（正規化。取込元を問わない共通形）
create table if not exists ar_receivables (
  id uuid primary key default gen_random_uuid(),
  recurring_master_id uuid references ar_recurring_master(id),
  source_name text not null,                             -- 入金元名（例: PayPay。将来複数入金元に対応）
  source_table text,                                      -- 元データの取込先テーブル名（例: import_paypay_settlement。監査・遡及用の自由記述）
  source_ref_id uuid,                                     -- 元データの行id（取込元によりテーブルが異なるため外部キー制約は張らない）
  year_month text not null,                               -- 対象月 YYYY-MM
  store_id uuid references stores(id),                    -- 店舗（共通費はnull）
  is_common_cost boolean not null default false,           -- 店舗特定できない月額利用料等の共通費（指示書§9-9・AIで按分しない）
  corporation_id uuid references corporations(id),
  gross_amount numeric not null default 0,                 -- 売上・決済額
  fee_amount numeric not null default 0,                    -- システム利用料・手数料
  expected_amount numeric not null default 0,               -- 入金予定額（通常 gross_amount - fee_amount）
  expected_date date,                                       -- 入金予定日
  status text not null default 'pending' check (status in ('pending','matched','diff','manual_review')),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table ar_receivables is
  '売上入金予定（会計・請求ワークスペースUI刷新Step4・指示書§9-8/9-9）。取込元ごとの生データ
   （import_paypay_settlement等・担当D管轄）を、取込元を問わない共通形に正規化したもの。
   statusは一覧の内部タブ（入金予定/差異あり/消込完了 等）にそのまま対応する。';
create index if not exists ar_receivables_ym_idx on ar_receivables(year_month);
create index if not exists ar_receivables_store_idx on ar_receivables(store_id);
create index if not exists ar_receivables_status_idx on ar_receivables(status);

-- ③ 実入金
create table if not exists ar_deposits (
  id uuid primary key default gen_random_uuid(),
  receivable_id uuid references ar_receivables(id),        -- 照合済みならセット。未照合はnull
  bank_source text,                                         -- 入金元口座・銀行名等（自由記述で十分。銀行口座マスタが要るほどの規模になったら見直す）
  deposit_date date not null,
  amount numeric not null,
  raw_ref text,                                             -- 銀行明細等の元データ参照（自由記述）
  created_at timestamptz not null default now()
);
comment on table ar_deposits is
  '実入金（会計・請求ワークスペースUI刷新Step4）。銀行口座への実際の入金記録。
   ar_receivablesと突合（消込）した結果はar_matchingに記録する。';
create index if not exists ar_deposits_receivable_idx on ar_deposits(receivable_id);
create index if not exists ar_deposits_date_idx on ar_deposits(deposit_date);

-- ④ 消込結果・差異ログ
create table if not exists ar_matching (
  id uuid primary key default gen_random_uuid(),
  receivable_id uuid not null references ar_receivables(id),
  deposit_id uuid references ar_deposits(id),
  diff_amount numeric not null default 0,                   -- 入金予定額と実入金額の差異（予定-実績）
  matched_at timestamptz,
  matched_by text,                                          -- 'auto' またはuser_idの文字列表現
  note text,
  created_at timestamptz not null default now()
);
comment on table ar_matching is
  '消込結果・差異ログ（会計・請求ワークスペースUI刷新Step4）。1つのar_receivablesに
   複数回の消込試行・部分入金の記録を残せるよう、履歴として追記する形にしている。';
create index if not exists ar_matching_receivable_idx on ar_matching(receivable_id);
