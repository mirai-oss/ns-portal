-- D-4: Anthropic API費用の自動レポート（日次データ保存先）
-- docs/実装指示書_担当D_勤怠給与監視_2026-08-24.md D-4
--
-- date: Anthropic Cost Report APIのbucketはUTC暦日単位（"snapped to the start of the day in UTC"）。
--   JSTではなくUTCの暦日をそのまま保存する（他のJST基準の日付列と混同しないよう明記）。
-- amount_cents: Cost Report APIのamount（USDセント建ての小数文字列。例"123.45"=$1.2345）をnumericで合算。
--   分数セントを含みうるためintegerではなくnumericにする。
-- jpy_rate/amount_jpy: 取得時点のその日（UTC暦日）のFrankfurter historical rateで換算し固定保存する
--   （2026-08-24ユーザー確定仕様。後から為替レートが変わっても当時の円額は変わらない）。

create table if not exists api_cost_daily (
  id uuid primary key default gen_random_uuid(),
  date date not null unique,
  amount_cents numeric not null,
  jpy_rate numeric,
  amount_jpy numeric,
  description text,
  updated_at timestamptz not null default now()
);
create index if not exists api_cost_daily_date_idx on api_cost_daily(date);
