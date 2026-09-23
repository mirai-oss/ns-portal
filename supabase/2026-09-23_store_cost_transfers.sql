-- =====================================================================
-- 店舗間の仕入れ（原価）移動を記録するテーブル（提案・未レビュー）
-- =====================================================================
-- 背景: docs/要望_推移分析営業区分絞込+店舗間仕入移動_2026-09-23.md（担当D発行）§2。
--   例: 9/1に本店で仕入れたサムゲタン10,000円分を芝店へ実際に融通した場合、本店の仕入から
--   10,000円差し引き、芝店の仕入へ10,000円加算し、両店の原価率にそれぞれ反映させたい。
--
-- 設計メモ（提案段階。担当Aがkeiei-kd-refresh(refreshPlMonthly)へ実装する際の土台として
--   このテーブルだけ先に作っておく。集計ロジック自体はこのファイルでは変更しない）:
--   - 1回の移動 = 1行。from_store_id側はマイナス、to_store_id側はプラスとして、
--     kd_pl_monthly_summaryの原価(F)集計に加算することを想定（cost_manualと同じ扱い）。
--   - 取り消しは行の削除ではなく canceled_at を立てるソフトデリート方式にして、
--     「いつ・誰が・何を取り消したか」の履歴を残す（cost_manual側の他の仕組みは削除方式だが、
--     店舗間のお金の動きは監査性を優先し、こちらはあえてソフトデリートにする提案）。
--   - pl_category は既定'F'（仕入）のみを主用途として想定しているが、将来他科目の店舗間付け替え
--     にも使えるようtext列にしている（現時点ではUIから'F'固定で登録する想定でよい）。
--
-- 実行場所: Supabase SQL Editor（https://supabase.com/dashboard/project/uuvsxzhpxtghojoubjcc/sql/new）
--   何度実行しても壊れません。
-- rollback: drop table if exists public.store_cost_transfers;
-- =====================================================================

create table if not exists public.store_cost_transfers (
  id uuid primary key default gen_random_uuid(),
  transfer_date date not null,                    -- 実際に移動した日（例: 2026-09-01）
  from_store_id uuid not null references public.stores(id),
  to_store_id uuid not null references public.stores(id),
  item_name text not null,                         -- 例: 'サムゲタン'
  amount numeric not null check (amount > 0),       -- 税別金額を想定（DB_PL他の仕入行と単位を揃える）
  pl_category text not null default 'F',            -- 既定=仕入。将来の拡張用
  note text,                                        -- 任意の備考
  created_by text,                                  -- 登録した人（ポータルのログインユーザー名等）
  created_at timestamptz not null default now(),
  canceled_at timestamptz,                          -- 取り消し時刻（nullなら有効）
  canceled_by text,
  constraint store_cost_transfers_different_stores check (from_store_id <> to_store_id)
);
create index if not exists store_cost_transfers_month_idx
  on public.store_cost_transfers ((to_char(transfer_date, 'YYYY-MM'))) where canceled_at is null;

alter table public.store_cost_transfers enable row level security;
drop policy if exists store_cost_transfers_select_authenticated on public.store_cost_transfers;
create policy store_cost_transfers_select_authenticated on public.store_cost_transfers for select to authenticated using (true);
-- 書き込みはservice_role経由（Edge Function等）のみを想定。anon/authenticatedへの書き込み許可はまだ付けていない
-- （UI側の実装方針＝どのAPI経由で書くか＝が決まってから、必要な分だけ許可を追加する）。

-- 確認用（実行後、空のテーブルが1件も無くエラーが出なければOK）:
-- select * from store_cost_transfers limit 1;
