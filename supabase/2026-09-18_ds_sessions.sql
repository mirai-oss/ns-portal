-- レーンP: セッション正本のSupabase化（A-11。実装指示書_ラウンド6_2026-09-18.md §1）
--
-- 背景: tori-dashboard GASのsessionPut/sessionGet/sessionDel（gas/Code.gs:535〜）は
-- token(UUID文字列)→{sess:{id,name,role,stores,tabs,perms,position,media}, exp:epoch millis}を
-- JSON文字列でPropertiesService（単一共有ストア）に保存している。利用者増で競合・容量の
-- 不安定要因になっているため、この正本をSupabaseの本テーブルへ移す（担当Aが新旧併用フラグで
-- 段階切替）。経営D・精算Dの両GASが同じテーブルを検証することで「ポータルで1回ログインすれば
-- 両方開く・勝手にログアウトしない」を実現する（A-11のスコープ強化）。
--
-- 設計方針（担当Aとのすり合わせ済み・2026-09-18）: GAS側の書き換えを最小化するため、
-- sessペイロードはそのままjsonbで1列に保持する（列を分解しない）。GASは既存のSUPABASE_URL/
-- SUPABASE_SERVICE_KEY（service_role）を使い、PostgREST経由で直接読み書きする想定
-- （token主キーでの単純なGET/UPSERT/DELETEのみ・複雑なクエリ不要）。
--
-- 呼び出しイメージ（GAS UrlFetchApp、service_roleキー使用）:
--   読む: GET .../rest/v1/ds_sessions?token=eq.<token>&select=sess,expires_at
--   延長保存（sliding TTL・PropertiesServiceと同じ「読むたび+336時間」）:
--     PATCH .../rest/v1/ds_sessions?token=eq.<token>  body:{expires_at:...,last_seen_at:'now()'}
--   新規発行: POST .../rest/v1/ds_sessions  body:{token,sess,expires_at}
--   ログアウト: DELETE .../rest/v1/ds_sessions?token=eq.<token>

create table if not exists public.ds_sessions (
  token text primary key,                              -- GAS側で発行するUUID文字列をそのまま使う
  sess jsonb not null,                                  -- {id,name,role,stores,tabs,perms,position,media}（GASの既存sessと同じ形。列分解しない）
  expires_at timestamptz not null,                      -- PropertiesServiceのexp(epoch millis)から変換。読むたびに+336時間へ延長するsliding TTL
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()       -- 最終アクセス時刻（強制ログアウト回数・失敗率の効果測定に使う）
);
create index if not exists ds_sessions_expires_idx on public.ds_sessions (expires_at);

alter table public.ds_sessions enable row level security;
-- 意図的にポリシーを1つも作らない＝anon/authenticatedからは一切アクセス不可（service_roleのみRLSを
-- バイパスして読み書きできる）。セッショントークンは実質パスワード相当のため、他のkd_テーブルのような
-- 「ログイン済みユーザーへの読み取り許可」は一切設けない。

comment on table public.ds_sessions is
  'A-11: tori-dashboard/seisan-dashboard共通のセッション正本（旧PropertiesService置き換え）。service_role限定・RLSポリシー無し（意図的）。古い行はkeiei-kd-refresh(op=sessions_cleanup)が定期削除する。';
