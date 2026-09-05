-- ============================================================
-- 業務委託精算書自動連携（担当C側・2026-09-05）
-- 設計書_業務委託精算書自動連携_2026-09-04.md §9-3のとおり、新テーブルは作らず
-- 既存invoice_pl_reflectionsを拡張する（Source of Truthの二重化を避けるため）。
--
-- reflection_route='direct'（既存）: pl-fee-reflectのconfirmがDB_PLへ直接書き込む経路。
--   1行に複数店舗のallocationsを持てる（従来どおり）。
-- reflection_route='seisan'（新規）: 業務委託精算書（seisan-dashboard）へ登録する経路。
--   設計書§4のとおり「1回の呼び出しは1店舗1明細」が前提のため、店舗ごとに1行作る
--   （allocationsは常に1要素の配列になる）。seisan_line_keyにはこの行のid（生成後に確定）を
--   使ったsourceKey（"invoice:<invoice_id>:<reflection_id>"）を保存し、同じ行への再登録は
--   同じsourceKeyでseisan-dashboard側も上書き（冪等）になるようにする。
-- ============================================================
alter table invoice_pl_reflections
  add column if not exists reflection_route text not null default 'direct'
    check (reflection_route in ('direct','seisan')),
  add column if not exists seisan_store_name text,      -- 精算書側の店舗名（stores.seisan_store_nameの値をそのまま複製）
  add column if not exists seisan_line_key text,         -- sd_apiAddExternalLineに渡すsourceKey（"invoice:<invoice_id>:<この行のid>"）
  add column if not exists item_name text,               -- 精算書の「費目名」列（設計書§1）。未指定ならaccount_nameを使う
  add column if not exists tax_rate text,                -- 精算書の「税率」列。'10%'|'8%'|'非課税'
  add column if not exists pl_status text not null default '振込確定待ち',
  add column if not exists pl_status_checked_at timestamptz;

create index if not exists ipr_route_idx on invoice_pl_reflections(reflection_route);

comment on column invoice_pl_reflections.reflection_route is
  '反映経路。direct=PLへ直接書き込み（既存）、seisan=業務委託精算書経由（2026-09-05新設）';
comment on column invoice_pl_reflections.pl_status is
  '設計書§9-2の6状態のいずれか: PL対象外 / 振込確定待ち / PL同期待ち / 店舗月次PL同期実行済み（個別反映未検証） / PL反映済み（個別確認済み） / PLエラー。directルートの行も含め都度この列で管理する';
