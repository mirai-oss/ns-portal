-- 法人移行期間: インフォマート経由の仕入は、2026年内はトーホーのインフォマートで立替（宛先=トーホー）が想定どおり（ユーザー確認 2026-10-17）。
-- 2027年からはN-Styleのインフォマートの請求書（宛先=N-Style）で、どちらも精算書でLiveGate宛に入れる。移行期間の検算（2026-11〜12）では、
-- インフォマートの請求書の期待法人を「トーホー」にする（運営会社=LiveGate とは比べない）。他の取引先は従来どおり運営会社と比べる。
update public.automation_rule_settings
   set params = params || '{"infomart_expected_corp_code":"toho"}'::jsonb, updated_at = now()
 where key = 'corp_transition';
