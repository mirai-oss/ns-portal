-- 賃金の取り込み前チェックを有効にする（2026-11-13・ユーザー承認「賃金取り込みの誤操作防止」）
--   有効のあいだ、スマレジ → 管理システムの賃金の取り込み（一括・1 人ぶん）は、スマレジにだけある行を正式な賃金として登録しない。
--   未承認の変更（新しい行・金額の違い・行の削除）として記録し、従業員一覧の「同期・承認の状況」に出す。一致の確認など、問題のない行は処理する。
--   入社登録が進行中の新しい人の初期投入だけは、これまでどおり取り込む（判定は wage_initial_import_users）。
--   スイッチ B（wage_import_hold）とは別の項目。B の値は変えない。戻すときは 2026-11-13_wage_import_precheck_off.sql
update app_settings set value = value || '{"wage_import_precheck": true}'::jsonb where key = 'employee_change';
