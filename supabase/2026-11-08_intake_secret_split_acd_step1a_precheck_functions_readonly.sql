-- =====================================================================
-- P0-1 手順1 事前確認 SQL 1（読み取りだけ・何も変えない）
--   本番DB関数のメタデータ・本文の指紋（md5）・権限、Vault 拡張の有無、public.app_secrets の対象行の有無
-- =====================================================================
-- ・関数本文・値・ヘッダ内容・設定値は出力しない（proconfig は設定名と md5 指紋のみ）。本文は DB 内で md5 にして期待値と比べ、一致／不一致だけ出す
-- ・照合は schema_name＋function_name＋引数（pg_get_function_identity_arguments）の3項目＝シグネチャ単位
-- ・同名で別シグネチャの関数があれば section='other_overload' として一覧に出す（拾い間違い防止）
-- ・結果は1つの表 → Export → CSV（Git管理外の一時領域に保存・ファイル名だけ報告・確認後に削除）
-- 実行場所: Supabase SQL Editor
-- =====================================================================
with expected(schema_name, function_name, args, expected_hash, source_file, gate) as (values
    ('public', 'indeed_intake', 'p_secret text, p_name text, p_job text, p_location text, p_store text, p_contact text, p_mail_id text, p_applied_at timestamp with time zone, p_url text', 'c45caa32b599d32c4f7e0b596e6b7c1a', '2026-08-21_intake_secret_rotation_part2.sql', true),
    ('public', 'indeed_message_intake', 'p_secret text, p_body text, p_mail_id text, p_from text, p_subject text, p_sent_at timestamp with time zone', '8e9ec1256a957b24f9183825558f558f', '2026-08-21_intake_secret_rotation_part2.sql', true),
    ('public', 'form_intake', 'p_secret text, p_name text, p_phone text, p_form_key text, p_answers jsonb, p_submitted_at timestamp with time zone, p_row_key text', '72fcb613f9c1e3afe925f777a2ca2663', '2026-08-21_intake_secret_rotation_part2.sql', true),
    ('public', 'indeed_fill_url', 'p_secret text, p_url text, p_mail_id text, p_name text, p_applied_at timestamp with time zone', 'b699a6f76def2cdf84d69aa658c952df', '2026-08-21_intake_secret_rotation_part2.sql', true),
    ('public', 'migrate_intake', 'p_secret text, p_name text, p_phone text, p_email text, p_form_key text, p_status text, p_applied_at timestamp with time zone, p_interview_at timestamp with time zone, p_note text, p_answers jsonb, p_row_key text', 'e1d5f61b51334dd7fadd5dfa9623251c', '2026-08-21_intake_secret_rotation_part2.sql', false),
    ('public', 'checklist_overdue_check', 'p_secret text', '2223c14bd8889c8fc2e39b4731b82a84', '2026-08-21_intake_secret_rotation.sql', true),
    ('public', 'checklist_intake_secret_ok', 'p_secret text', '989c4d9441f3c2fbeec16bc60df78f9e', '2026-08-21_intake_secret_rotation.sql', true),
    ('public', 'line_intake', 'p_secret text, p_line_user_id text, p_text text, p_event_id text, p_sent_at timestamp with time zone', 'e62917622e6efeda439b27bd04b94885', '2026-08-21_intake_secret_rotation.sql', false),
    ('public', 'line_log_out', 'p_secret text, p_applicant uuid, p_text text', '93e27fbd4051e654cc6882c517b41837', '2026-08-21_intake_secret_rotation.sql', false),
    ('public', 'mark_interview_reminded', 'p_secret text, p_applicant uuid', '078fc15bd505a90b8a7c43e052da23bb', '2026-08-21_intake_secret_rotation.sql', false),
    ('public', 'recruit_mark_reminded', 'p_secret text, p_applicant uuid', '377de0a44c9f3a414f855d5a8dfc3aba', '2026-08-21_intake_secret_rotation.sql', false),
    ('public', 'recruit_daily_targets', 'p_secret text', 'a05a11c68f3b708d0c1d34996b62c442', '2026-08-21_intake_secret_rotation.sql', false),
    ('public', 'line_intake_user', 'p_secret text, p_line_user_id text, p_text text', 'aacf4552424621ac0388a588538e74c6', '2026-09-01_line_link_unify.sql', false)
),
fn as (
  select n.nspname as schema_name, p.proname as function_name,
         pg_get_function_identity_arguments(p.oid) as args,
         pg_get_function_result(p.oid) as returns_type,
         l.lanname as language,
         case p.provolatile when 'i' then 'immutable' when 's' then 'stable' else 'volatile' end as volatility,
         p.proisstrict as strict,
         case p.proparallel when 's' then 'safe' when 'r' then 'restricted' else 'unsafe' end as parallel,
         -- 設定は名前だけ＋全体の指紋（値は出さない）
         (select string_agg(split_part(c, '=', 1), '; ' order by c) from unnest(p.proconfig) as c) as proconfig_keys,
         md5(coalesce(array_to_string(p.proconfig, ';'), '')) as proconfig_hash,
         r.rolname as owner,
         p.prosecdef as security_definer,
         has_function_privilege('anon', p.oid, 'execute') as anon_exec,
         has_function_privilege('authenticated', p.oid, 'execute') as authenticated_exec,
         has_function_privilege('service_role', p.oid, 'execute') as service_role_exec,
         coalesce(p.proacl::text, '(既定=PUBLIC実行可)') as acl,
         md5(p.prosrc) as body_hash
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    join pg_language l on l.oid = p.prolang
    join pg_roles r on r.oid = p.proowner
   where n.nspname = 'public' and p.proname in (select function_name from expected)
)
select case when e.function_name is not null then 'function' else 'other_overload' end as section,
       fn.schema_name, fn.function_name, fn.args, fn.returns_type, fn.language, fn.volatility, fn.strict, fn.parallel,
       fn.proconfig_keys, fn.proconfig_hash, fn.owner, fn.security_definer, fn.anon_exec, fn.authenticated_exec, fn.service_role_exec, fn.acl,
       fn.body_hash, e.expected_hash, e.source_file,
       case when e.function_name is null then '想定外の同名関数（シグネチャ不一致）'
            when fn.body_hash = e.expected_hash then '一致' else '不一致' end as match_result,
       case when e.gate then '手順3/8で差し替える（一致が必須）'
            when e.function_name is not null then '参考（E・権限変更のみ）' else '要確認' end as note
  from fn
  left join expected e on e.schema_name = fn.schema_name and e.function_name = fn.function_name and e.args = fn.args
union all
select 'missing', e.schema_name, e.function_name, e.args, null, null, null, null, null, null, null, null, null, null, null, null, null,
       null, e.expected_hash, e.source_file, '本番に存在しない（このシグネチャ）', case when e.gate then '停止条件' else '参考' end
  from expected e
 where not exists (select 1 from fn where fn.schema_name = e.schema_name and fn.function_name = e.function_name and fn.args = e.args)
union all
select 'check', 'vault', 'extension_installed', null, null, null, null, null, null, null, null, null, null, null, null, null, null,
       null, null, null,
       case when exists (select 1 from pg_extension where extname = 'supabase_vault') then 'あり → SQL 2 を実行' else 'なし → 停止（Vault を有効にしてから）' end,
       'Vault 拡張の有無'
union all
select 'check', 'public.app_secrets', 'prev_row_exists', null, null, null, null, null, null, null, null, null, null, null, null, null, null,
       null, null, null,
       case when exists (select 1 from public.app_secrets where key = 'checklist_intake_secret_prev') then 'あり（手順8で削除）' else 'なし' end,
       '公開済み旧値の行の有無（値は出さない）'
union all
select 'check', 'public.app_secrets', 'current_row_exists', null, null, null, null, null, null, null, null, null, null, null, null, null, null,
       null, null, null,
       case when exists (select 1 from public.app_secrets where key = 'checklist_intake_secret') then 'あり' else 'なし' end,
       'E 内部用の現在値の行の有無（値は出さない）'
order by 1, 3, 4;
