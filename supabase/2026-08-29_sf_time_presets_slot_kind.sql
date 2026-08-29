-- ============================================================
-- シフト仕上げ B-2（旧要望E）: ランチ/ディナーで店舗ごとにシフトを分ける — 担当B
-- 実装指示書_担当B_シフト仕上げと機能追加_2026-08-29.md B-2 参照。
-- 既存テーブルsf_time_presetsへの列追加のみ（既存SQLファイルは無編集）。
-- 追加列はnullable・既定null＝「一括」扱いなので、時間帯を分けていない従来店舗は無影響。
-- 実行場所: Supabase SQL Editor / Management API（何度実行しても壊れません）
-- ============================================================

alter table sf_time_presets add column if not exists slot_kind text check (slot_kind in ('lunch','dinner'));
