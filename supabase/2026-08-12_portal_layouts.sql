-- ============================================================
-- ポータルホームの総合ダッシュボード化: 役割ごとの画面レイアウト設定
-- 画面=ポータル（index.html）／データ=ハブ。既存テーブルは無変更。
-- 対象: 実装指示書_ポータルホーム改修.md
-- 冪等。
-- ============================================================

create table if not exists portal_layouts (
  role text not null,          -- MASTER/CEO/HQ/TEAM/TENCHO/SHAIN/AL（MASTERは役割と独立の仮想役割として扱う）
  area text not null,          -- kpi / main / side / wide
  widget_key text not null,
  position int not null default 100,
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key (role, area, widget_key)
);

alter table portal_layouts enable row level security;
-- 読み=ログイン全員（自分の役割の構成を組み立てるために必要）
drop policy if exists pl_read on portal_layouts;
create policy pl_read on portal_layouts for select using (auth.uid() is not null);
-- 書き=マスターのみ（既存のportal_is_master()を利用。新関数は作らない）
drop policy if exists pl_write on portal_layouts;
create policy pl_write on portal_layouts for all using (portal_is_master()) with check (portal_is_master());
