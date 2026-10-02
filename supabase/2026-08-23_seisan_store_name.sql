-- =====================================================================
-- 精算システム側の店舗名（表記ゆれ吸収用）— 運営委託費PL自動連携
-- =====================================================================
-- 背景: 運営委託費の自動連携(syncSeisanFeeToPl)で、Supabase側の店舗名
--   （例:「じんべぇ 川崎」）と精算ダッシュボード側の店舗名（例:「川崎　じんべぇ」
--   ＝地名が先・全角スペース区切り）が一致せず、業務委託4店舗中3店舗が
--   「データ無し」でスキップされていた（2026-08-23の実地テストで発覚）。
-- 方針: dash_store_name（既存・dash-sync専用で用途が違う）とは別に、
--   精算システム専用の別名列を新設する。空なら店舗名(name)をそのまま使う
--   （＝表記が一致している店舗は何も設定しなくてよい）。
-- 実行場所: Supabase SQL Editor（何度実行しても壊れません）
-- =====================================================================

alter table public.stores add column if not exists seisan_store_name text;
comment on column public.stores.seisan_store_name is
  '精算ダッシュボード側の店舗名（表記が違う場合のみ設定。空なら stores.name を使う）';

-- 現時点で判明している3店舗分を先に埋めておく（精算システム側の実際の表記そのまま）
update public.stores set seisan_store_name = '川崎　じんべぇ'   where name = 'じんべぇ 川崎';
update public.stores set seisan_store_name = '新横浜　じんべぇ' where name = 'じんべぇ 新横浜';
update public.stores set seisan_store_name = '本厚木 エース'    where name = 'エース 本厚木';
-- 参考: 黒霧屋 新横浜 は精算対象(seisan_target)ではないため今回は対象外だが、
-- 精算システム側には「新横浜　黒霧屋」という表記で存在することが判明している。
-- 将来 seisan_target を立てる場合に備えて別名だけ記録しておく。
update public.stores set seisan_store_name = '新横浜　黒霧屋'   where name = '黒霧屋 新横浜';

-- store_directory_v に列を追加（既存の列・他のビューには影響しない）
create or replace view public.store_directory_v as
select
  s.id,
  s.store_no,
  s.name,
  s.signs,
  c.name as corporation_name,
  s.sort_order,
  s.is_active,
  s.weather_lat,
  s.weather_lon,
  s.seisan_target,
  s.file_key,
  coalesce(
    (select jsonb_agg(jsonb_build_object('alias', a.alias, 'kind', a.kind, 'source', a.source) order by a.alias)
     from public.store_aliases a where a.store_id = s.id),
    '[]'::jsonb
  ) as aliases,
  s.seisan_store_name
from public.stores s
left join public.corporations c on c.id = s.corporation_id;

grant select on public.store_directory_v to anon;
