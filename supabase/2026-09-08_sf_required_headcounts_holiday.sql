-- 2026-09-08 担当B（nippo）
-- ユーザー指示「設定のところに曜日に祝日、祝前日は入れる」に対応。
-- 必要人数設定(sf_required_headcounts)は従来、曜日(0-6)または特定日でしか条件指定できず、
-- 「祝日は多めに必要」「祝前日は多めに必要」のような、実際の日付が変動する条件を
-- 店舗ごとに設定できなかった。special_day_typeを追加し、weekday/specific_dateと並ぶ
-- 3つ目の条件軸として使えるようにする（優先順位: 特定日 > 祝日/祝前日 > 曜日。
-- アプリ側のsfV12FindHeadcountReqで判定）。

alter table sf_required_headcounts add column if not exists special_day_type text check (special_day_type in ('holiday','holiday_eve'));
comment on column sf_required_headcounts.special_day_type is '祝日(holiday)/祝前日(holiday_eve)指定。指定時はweekdayより優先。2026-09-08追加';
