-- スマレジ複数契約対応 Phase2（未適用）: sf_payroll_syncの旧一意制約 (user_id, year_month) を外す（担当D・2026-10-17）
-- 前提（この順で）: ①Phase1(2026-10-17d)適用済み ②smaregi-payroll-sync を contract_id 対応版（onConflict: user_id,year_month,contract_id）へ
--   デプロイ済み（旧版のままこの制約を外すと、旧版のupsert(onConflict: user_id,year_month)が失敗する）
--   ③LiveGate契約の初回同期の直前に適用（兼務の人に契約ごとの2行を持たせられるようになる）
-- 【影響】兼務の人（LiveGateの行が入った人）だけ「人×年月」が2行になる。sf_payroll_syncを user_id+year_month で結合している
--   SQL関数（hq_create_payroll_tasks・cash_handoff_*・team_role_store_scope_fallback 等）と画面（給与仕訳=担当C／nippo=担当B）は、
--   兼務の人で行が2倍になる（後述の対応が必要）。
-- 【rollback】 alter table sf_payroll_sync add constraint sf_payroll_sync_user_id_year_month_key unique (user_id, year_month);
--   （LiveGate行が既に入っている場合は、先にそれらを退避・削除しないと復元できない）
alter table public.sf_payroll_sync drop constraint if exists sf_payroll_sync_user_id_year_month_key;
