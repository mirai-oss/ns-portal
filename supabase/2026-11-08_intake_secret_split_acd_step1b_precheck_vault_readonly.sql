-- =====================================================================
-- P0-1 手順1 事前確認 SQL 2（読み取りだけ・何も変えない）: Vault の読み取り可否と、必要な Secret 名の有無
-- =====================================================================
-- ・SQL 1 の extension_installed が「あり」のときだけ実行する
-- ・値は出さない（名前の有無と可否だけ）
-- 実行場所: Supabase SQL Editor
-- =====================================================================
select 'vault' as section, 'decrypted_secrets_readable_by_postgres' as item,
       case when has_table_privilege('postgres', 'vault.decrypted_secrets', 'select') then '読める' else '読めない → 停止' end as result,
       '手順3で作る判定関数（所有者 postgres・SECURITY DEFINER）が Vault を読める前提の確認' as note
union all
select 'vault', 'secret_exists: recruit_intake_secret',
       case when exists (select 1 from vault.secrets where name = 'recruit_intake_secret') then 'あり' else 'なし（手順2で登録）' end,
       'C 採用取込用'
union all
select 'vault', 'secret_exists: checklist_alert_secret',
       case when exists (select 1 from vault.secrets where name = 'checklist_alert_secret') then 'あり' else 'なし（手順2で登録）' end,
       'D 期限切れ点検用'
order by 2;
