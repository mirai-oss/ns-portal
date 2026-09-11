-- 設計書_デリバリー売上取込_ロケットナウ_2026-09-11.md §2「チャネル×店舗対応表」。担当D Phase1分。
--
-- 【理由】ロケットナウ等デリバリーチャネルの明細は、当社の店舗名ではなく「チャネル側の店舗ID」
-- （例: ロケットナウの54887=鳥一代本店）で店舗を識別している。既存のstore_aliases（店舗“名”の
-- 表記ゆれ吸収）とはキー空間が違うため、別テーブルとして新設する（設計書どおり「D管理画面不要
-- =SQLシード＋未知IDは隔離＆Lark」の方針）。
--
-- 【影響】新規テーブル追加のみ。既存テーブル・既存ジョブに影響なし。
-- 【rollback】 drop table if exists public.delivery_store_map;

create table if not exists public.delivery_store_map (
  channel text not null,                        -- 'rocketnow' / 将来 'ubereats' 等
  channel_store_id text not null,                -- チャネル側の店舗ID（例 '54887'）
  store_id uuid not null references public.stores(id),
  channel_store_name text,                       -- チャネル側の店舗名表示（参考用。正本はstores.name）
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (channel, channel_store_id)
);
alter table public.delivery_store_map enable row level security;
drop policy if exists delivery_store_map_select_authenticated on public.delivery_store_map;
create policy delivery_store_map_select_authenticated on public.delivery_store_map for select to authenticated using (true);

-- 実ファイル2本（sales-report(Multi)_20260910・sales-report(54887)_20260812）に登場した2店舗を先行登録。
-- 他店舗のIDが取込時に見つかれば、kd_unresolved_namesへ隔離登録＋Lark通知されるので、そこから追記していく。
insert into public.delivery_store_map (channel, channel_store_id, store_id, channel_store_name) values
  ('rocketnow', '54887', 'bee9f74a-2079-4cf1-87d6-eb758e193d33', '鳥一代 本店'),
  ('rocketnow', '55662', 'eecb30b6-3687-407c-8e11-54d9a6cccd18', '鳥一代 はなれ')
on conflict (channel, channel_store_id) do update set
  store_id = excluded.store_id, channel_store_name = excluded.channel_store_name;
