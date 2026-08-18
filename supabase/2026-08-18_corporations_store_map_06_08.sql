-- ============================================================
-- 法人マスタ統一の続き: 店舗06〜08の corporation_id 確定
-- （2026-08-17_corporations.sql では info.stores に収録が無く未確定のまま残していた分。
--  ユーザー回答: 06鶏武者新横浜／07鶏武者川崎店／08黒霧屋新横浜は
--  いずれも有限会社トーホーエージェンシーが運営）
-- 冪等（既に正しい値ならUPDATEは0件、再実行しても壊れない）。
-- ============================================================
update stores s set corporation_id = c.id
from corporations c
where c.corp_code = 'toho' and s.store_no in ('06','07','08') and s.corporation_id is distinct from c.id;
