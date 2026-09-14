-- 指示書_デリバリー売上取込_担当別_2026-09-11.md「担当Aへ」③。
--
-- 【理由】既存の媒体名寄せロジック（tpl_media_alias）が、デリバリー売上（ロケットナウ）の
-- media_name='ロケットナウ'をraw_mediaとして受け取ったときに未登録のまま素通りするよう、
-- 自己参照（raw_media=canonical_media）で正規名を登録しておく。
--
-- 【影響】新規行の追加のみ。既存行・既存ロジックへの影響なし。
-- 【rollback】 delete from public.tpl_media_alias where raw_media='ロケットナウ';
--
-- Supabase Management APIで2026-09-14に適用済み（本ファイルは記録用）。

insert into public.tpl_media_alias (raw_media, canonical_media) values
  ('ロケットナウ', 'ロケットナウ')
on conflict (raw_media) do nothing;
