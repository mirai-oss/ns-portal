-- エイリアス列の統合（調査レポート_店舗法人マスタ統一_2026-08-26.md ③・ユーザー確定 2026-08-28）
-- dash_store_name（tori-dashboard向け）・seisan_store_name（精算システム向け）を、
-- 既存の汎用テーブル store_aliases（alias→store_idの対応表）へデータ移行する。
-- 追加のみ・既存列（dash_store_name/seisan_store_name）は消さずそのまま残す
-- （今動いている各システムのコードに影響を与えないため。読み替えの切替は各担当が
-- 個別に対応する＝WORKLOG経由で依頼）
-- 実行方法: Supabase SQL Editor（ハブ本体・publicスキーマ）

-- dash_store_name → store_aliases（source='tori-dashboard'）
insert into public.store_aliases (alias, store_id, source, kind)
select trim(s.dash_store_name), s.id, 'tori-dashboard', 'name'
from public.stores s
where s.dash_store_name is not null
  and trim(s.dash_store_name) <> ''
on conflict (alias) do nothing; -- 既に同じ文字列が別名として登録済みならスキップ（衝突時は手動確認）

-- seisan_store_name → store_aliases（source='精算システム'）
insert into public.store_aliases (alias, store_id, source, kind)
select trim(s.seisan_store_name), s.id, '精算システム', 'name'
from public.stores s
where s.seisan_store_name is not null
  and trim(s.seisan_store_name) <> ''
on conflict (alias) do nothing;

-- 確認用（実行後に見るだけ・変更なし）
-- select alias, source, kind, s.name as 店舗名
-- from public.store_aliases a join public.stores s on s.id = a.store_id
-- where a.source in ('tori-dashboard','精算システム')
-- order by s.store_no;
