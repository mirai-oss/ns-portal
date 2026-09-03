-- PL反映の対象を「一部の勘定科目だけ」から「会計入力（仕訳登録）した請求書すべて」に拡張（2026-09-03）
-- ユーザー要望: 「管理システム側で会計入力したものを、全てPL反映させるかどうかの欄は作成してほしい。
-- そのPLのどこの店舗のどこの勘定科目、補助科目に反映させるか？は会計仕訳、入力したものを拾って、
-- PLに連携されるようにしてほしい！（PL連携前に内容を確認で出してほしい。）」
--
-- 従来（ラウンド5§6.1・2026-09-01）はinvoices.pl_fee_*列（1請求書につき1科目のみ）＋
-- mf_pl_fee_accounts（事前登録した科目だけがPL反映パネルの対象になる仕組み）だった。
-- 今回、1請求書の仕訳に複数の勘定科目（例: 消耗品費＋支払手数料）が混ざっていても、
-- 科目ごとに個別にPLへ反映できるよう、実績を複数行持てるテーブルへ拡張する。

-- 1請求書につき「勘定科目×補助科目」の組み合わせごとに1行（複数の科目を反映すれば複数行になる）
create table if not exists invoice_pl_reflections (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references invoices(id),
  account_name text not null,
  sub_account_name text,             -- 補助科目（無ければnull）
  year_month date not null,
  allocations jsonb not null,        -- 店舗×金額の割り振り（[{store_id,store_name,amount}]）
  reflected_at timestamptz not null default now(),
  reflected_by uuid references users(id),
  sheet_synced_at timestamptz,       -- tori-dashboard（DB_PL・精算書）への書き込みが完了した日時
  sheet_sync_error text,
  created_at timestamptz not null default now()
);
alter table invoice_pl_reflections enable row level security;
drop policy if exists ipr_all on invoice_pl_reflections;
create policy ipr_all on invoice_pl_reflections for all
  using (invoice_can_access()) with check (invoice_can_access());
create index if not exists ipr_invoice_idx on invoice_pl_reflections(invoice_id);
create index if not exists ipr_account_ym_idx on invoice_pl_reflections(account_name, sub_account_name, year_month);

-- 既存データの移行: 旧方式（1請求書1科目）で既にPL反映済みだった請求書を、そのまま1行として引き継ぐ
-- （補助科目は旧方式では記録していなかったためnull）
insert into invoice_pl_reflections
  (invoice_id, account_name, sub_account_name, year_month, allocations, reflected_at, reflected_by, sheet_synced_at, sheet_sync_error)
select id, pl_fee_account, null, pl_fee_year_month, pl_fee_allocations, pl_fee_reflected_at, pl_fee_reflected_by, pl_fee_sheet_synced_at, pl_fee_sheet_sync_error
from invoices
where pl_fee_reflected_at is not null and pl_fee_account is not null
  and id not in (select invoice_id from invoice_pl_reflections);

-- 「この請求書はPLに反映しない」という明示的な決定を記録（対象外・取り消し可能）
alter table invoices add column if not exists pl_fee_excluded_at timestamptz;
alter table invoices add column if not exists pl_fee_excluded_by uuid references users(id);

-- 備考: invoices.pl_fee_reflected_at / pl_fee_account / pl_fee_year_month / pl_fee_allocations は
-- 「請求書一覧・会計ダッシュボードのバッジ表示用」の簡易フラグとして今後も使い続ける
-- （pl_fee_reflected_atは「最初にPLへ反映した日時」を1回だけ記録する。詳細=科目ごとの内訳は
-- invoice_pl_reflectionsを見る）。列自体を削除・置き換えるものではない。
