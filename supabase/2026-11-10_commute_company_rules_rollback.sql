-- 切り戻し: 2026-11-10_commute_company_rules.sql（データ保全: 列と値は残す。関数と設定の追記キーだけ外す）
drop function if exists public.onboarding_set_commute_policy(uuid, text, integer, boolean, text, uuid);
update app_settings set value = (value - 'fare_type' - 'allow_bus' - 'allow_express' - 'daily_cap_round_yen' - 'use_address_lookup') || jsonb_build_object('cap_unit', 'unknown') where key = 'commute_rules';
-- employee_commute の pay_policy / expected_days_per_month / bus_exception / policy_* 列は残す（古い EF は読まないので害はない）
