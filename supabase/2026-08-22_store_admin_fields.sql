-- ============================================================
-- データ基盤統合ロードマップ Day6「店舗追加の1箇所化」
-- nippoの店舗管理画面拡張で使う新規列（すべて既存stores行には影響しない追加のみ・冪等）。
-- 天気地点（緯度経度）・Lark配信フラグ・精算対象フラグは、これまでどのシステムにも
-- 存在しなかった新しい情報のため、ここで初めて正本を作る。
-- ============================================================

alter table public.stores
  add column if not exists weather_lat numeric,
  add column if not exists weather_lon numeric,
  add column if not exists lark_enabled boolean not null default false,
  add column if not exists seisan_target boolean not null default false;

comment on column public.stores.weather_lat is '天気取得に使う緯度（経営ダッシュボードWX_LOCSの代替。店舗単位で設定。未設定なら地域デフォルトにフォールバック）';
comment on column public.stores.weather_lon is '天気取得に使う経度';
comment on column public.stores.lark_enabled is 'Lark自動日報の配信対象かどうか（経営ダッシュボードのLark配信matrix自動生成で使用予定）';
comment on column public.stores.seisan_target is '精算ダッシュボードでの精算対象店舗かどうか';
