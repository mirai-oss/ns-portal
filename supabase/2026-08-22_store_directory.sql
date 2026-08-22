-- ============================================================
-- データ基盤統合ロードマップ Day6②③「経営D GASのSupabase直読み」＋「配信matrix自動生成（Chatwork対応）」
-- 設計の正: docs/実装指示書_Day6_店舗マスタ1箇所化②③.md §1
-- 冪等: 何度実行しても安全。既存列・既存行の削除／改名はしない（追加のみ）。
-- ============================================================

-- ------------------------------------------------------------
-- 1) store_aliases.kind（決定2: 親子ブランド＝別名の一種として表現）
--    name   = 表記ゆれ（正準名の言い換え）
--    listing = 口コミ・広告媒体上の別掲載名（旧REVIEW_CHILDREN／DB_店舗親子相当）
-- ------------------------------------------------------------
alter table public.store_aliases add column if not exists kind text not null default 'name';

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'store_aliases_kind_check') then
    alter table public.store_aliases add constraint store_aliases_kind_check check (kind in ('name','listing'));
  end if;
end $$;

-- ------------------------------------------------------------
-- 2) stores.file_key（配信レポート画像のファイル名キー。現行Lark matrixの値を引き継ぐ）
-- ------------------------------------------------------------
alter table public.stores add column if not exists file_key text;
comment on column public.stores.file_key is '経営ダッシュボードの自動レポート画像のファイル名キー（例: honten）。配信matrix自動生成で使用';

-- ------------------------------------------------------------
-- 3) 配信チャネル（決定4: チャネル非依存化。Lark/Chatwork混在可）
-- ------------------------------------------------------------
create table if not exists public.report_channels (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,                                   -- 例: group1
  kind text not null default 'lark' check (kind in ('lark','chatwork')),
  secret_name text not null,                                   -- GitHub Secretの「名前」のみ（値は絶対にDBへ置かない）
  chatwork_room_id text,                                        -- kind='chatwork'のとき使用
  keyword text,                                                 -- Larkのカスタムキーワード（未使用ならnull）
  report_kinds text[] not null default array['daily','weekly','monthly'],
  is_active boolean not null default true,
  sort_order int not null default 100,
  created_at timestamptz not null default now()
);

create table if not exists public.report_channel_stores (
  channel_id uuid not null references public.report_channels(id) on delete cascade,
  store_id uuid not null references public.stores(id) on delete cascade,
  sort_order int not null default 100,
  primary key (channel_id, store_id)
);

alter table public.report_channels enable row level security;
drop policy if exists rc_read on public.report_channels;
create policy rc_read on public.report_channels for select using (auth.uid() is not null);
drop policy if exists rc_write on public.report_channels;
create policy rc_write on public.report_channels for all
  using (checklist_can_manage()) with check (checklist_can_manage());

alter table public.report_channel_stores enable row level security;
drop policy if exists rcs_read on public.report_channel_stores;
create policy rcs_read on public.report_channel_stores for select using (auth.uid() is not null);
drop policy if exists rcs_write on public.report_channel_stores;
create policy rcs_write on public.report_channel_stores for all
  using (checklist_can_manage()) with check (checklist_can_manage());

-- ------------------------------------------------------------
-- 4) 匿名読み取り専用VIEW（決定1）。列はホワイトリストで明示列挙（select * 禁止）。
--    smaregi_store_id・内部メモ類・stores の他の管理用列は含めない。
--    Viewはowner権限で実行される（Supabaseの標準パターン）ため、anonへのgrantだけで
--    stores/store_aliases/report_channels本体のRLS（ログイン必須）は回避せずに済む
--    （本体テーブルへのanon grantは行わない）。
-- ------------------------------------------------------------
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
  ) as aliases
from public.stores s
left join public.corporations c on c.id = s.corporation_id;

grant select on public.store_directory_v to anon;

create or replace view public.report_channel_matrix_v as
select
  rc.id,
  rc.name as "group",
  rc.kind,
  rc.secret_name,
  rc.chatwork_room_id,
  rc.keyword,
  rc.report_kinds,
  string_agg(s.name || '|' || coalesce(s.file_key, ''), ',' order by rcs.sort_order, s.sort_order) as stores
from public.report_channels rc
join public.report_channel_stores rcs on rcs.channel_id = rc.id
join public.stores s on s.id = rcs.store_id
where rc.is_active and s.is_active
group by rc.id, rc.name, rc.kind, rc.secret_name, rc.chatwork_room_id, rc.keyword, rc.report_kinds
order by rc.sort_order;

grant select on public.report_channel_matrix_v to anon;

-- ------------------------------------------------------------
-- 5) seed（決定5: 既存12店舗の値。ユーザーがnippo店舗管理画面で後日確認）
-- ------------------------------------------------------------

-- 5-1) 現行Lark3グループをそのままseed（切替後の初回配信が現行と同一になることの土台）
insert into public.report_channels(name, kind, secret_name, report_kinds, sort_order) values
  ('group1', 'lark', 'LARK_WEBHOOK_GROUP1', array['daily','weekly','monthly'], 1),
  ('group2', 'lark', 'LARK_WEBHOOK_GROUP2', array['daily','weekly','monthly'], 2),
  ('group3', 'lark', 'LARK_WEBHOOK_GROUP3', array['daily','weekly','monthly'], 3)
on conflict (name) do nothing;

insert into public.report_channel_stores(channel_id, store_id, sort_order)
select rc.id, s.id, v.ord
from (values
  ('group1','01',1), ('group1','02',2), ('group1','03',3), ('group1','05',4),
  ('group2','04',1), ('group2','08',2), ('group2','07',3),
  ('group3','08',1), ('group3','07',2), ('group3','06',3)
) as v(channel_name, store_no, ord)
join public.report_channels rc on rc.name = v.channel_name
join public.stores s on s.store_no = v.store_no
on conflict (channel_id, store_id) do nothing;

-- 5-2) file_key（現行workflow matrixの値をそのまま引き継ぎ）
update public.stores set file_key = v.file_key
from (values
  ('01','honten'), ('02','hanare'), ('03','shiba'), ('05','shinbashi'),
  ('04','ebisu'), ('08','kurokiriya-shinyoko'), ('07','torimusha-kawasaki'), ('06','torimusha-shinyoko')
) as v(store_no, file_key)
where public.stores.store_no = v.store_no and public.stores.file_key is distinct from v.file_key;

-- 5-3) weather_lat/lon（決定3: 現行WX_LOCSの正規表現判定と同じ結果になるようバックフィル）
--     yokohama: /新横浜|横浜|川崎|うお蔵|黒霧屋|鶏武者|匠味|彩/ → 01,02,03,05,12は非該当なのでtokyoへ
update public.stores set weather_lat = 35.4437, weather_lon = 139.6380
  where store_no in ('06','07','08','09','10') and weather_lat is null;
--     atsugi: /本厚木|厚木|エース/
update public.stores set weather_lat = 35.4408, weather_lon = 139.3648
  where store_no in ('11') and weather_lat is null;
--     tokyo（既定）
update public.stores set weather_lat = 35.6895, weather_lon = 139.6917
  where store_no in ('01','02','03','05','12') and weather_lat is null;

-- 5-4) seisan_target（要件定義書§4の委託4店舗）
update public.stores set seisan_target = true where store_no in ('09','10','11','12');

-- 5-5) store_aliases(kind='listing')（決定2: REVIEW_CHILDREN由来。DB_店舗親子シートの内容は
--     GASログイン権限が必要で本SQLからは取得できないため未反映。ユーザーがnippo店舗管理画面で
--     追加確認・補完すること＝受入チェックリストの「seed後の12店舗をユーザーが画面で確認」でカバー）
update public.store_aliases set kind = 'listing' where alias in ('匠味 新横浜', '匠味 川崎');

insert into public.store_aliases(alias, store_id, source, kind)
select v.alias, s.id, 'Google口コミ', 'listing'
from (values
  ('カラオケ 彩-irodori 新横浜アリーナ通り店', '08'),
  ('うお蔵 新横浜', '08')
) as v(alias, store_no)
join public.stores s on s.store_no = v.store_no
on conflict (alias) do nothing;

-- ------------------------------------------------------------
-- 6) 確認クエリ（実行後に目視確認する用）
-- ------------------------------------------------------------
-- select * from store_directory_v order by sort_order;
-- select * from report_channel_matrix_v order by "group";
-- select store_no, name, file_key, weather_lat, weather_lon, seisan_target from stores order by store_no;
-- select alias, kind, source, store_id from store_aliases where kind='listing' order by store_id;
