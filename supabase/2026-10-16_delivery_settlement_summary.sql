-- ロケットナウ「精算履歴」(settlement-report) の月次合計（損失補償・支給額を含む）の保存先（2026-10-16 担当C）
-- 取り込みは Mac mini の rocketnow-settlement 系ジョブ（担当D）が service key で upsert する。
-- 検算式: payout = sales + total_fee + tax + store_discount + ad_total + loss_compensation + rn_fee_discount + cancel_amount
--   （手数料・消費税・広告・キャンセルはファイル上マイナスの値で入る）
create table if not exists public.delivery_settlement_summary (
  id uuid primary key default gen_random_uuid(),
  channel text not null default 'rocketnow',
  store_id uuid,
  store_name text not null,
  channel_store_id text,
  pay_date date not null,
  period_start date not null,
  period_end date not null,
  sales numeric,               -- 売上金額（キャンセル控除前）
  total_fee numeric,           -- 総手数料（3%決済手数料を含む）
  store_discount numeric,      -- 店舗負担の割引金額
  tax numeric,                 -- 消費税
  ad_fee numeric,              -- 広告費
  ad_credit numeric,           -- 広告支援クレジット
  ad_adjust numeric,           -- 広告費調整額（返金）
  ad_total numeric,            -- 広告費合計
  loss_compensation numeric,   -- 損失補償（ロケットナウ→店舗。売上として計上: デリバリー売上/ロケットなう）
  rn_fee_discount numeric,     -- RocketNow手数料割引
  cancel_amount numeric,       -- キャンセル注文金額
  payout numeric not null,     -- 支給額（実際の入金額）
  checksum_ok boolean,         -- 検算式が合ったか（取込側で計算）
  source_file text,
  imported_at timestamptz not null default now(),
  unique (channel, store_name, period_start, period_end)
);
create index if not exists delivery_settlement_summary_pay_idx on public.delivery_settlement_summary(pay_date);
alter table public.delivery_settlement_summary enable row level security;
drop policy if exists delivery_settlement_summary_read_inv on public.delivery_settlement_summary;
create policy delivery_settlement_summary_read_inv on public.delivery_settlement_summary for select using (invoice_can_access());
-- 書き込みは service key（RLSをバイパス）のみ。
