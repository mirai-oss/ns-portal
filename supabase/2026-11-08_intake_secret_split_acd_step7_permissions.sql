-- =====================================================================
-- P0-1 手順7（E）: サーバー内部専用RPC・合言葉チェック関数の実行権限を service_role だけにする
-- =====================================================================
-- 対象 10本: PUBLIC／anon／authenticated から実行不可、service_role のみ実行可。
-- line-webhook は service_role で呼ぶため影響なし。画面コード（nippo/ns-portal 等）からの直接呼び出しは 0件（2026-11-08 調査）。
-- GAS が直接呼ぶ C/D の RPC 5本（indeed_intake / indeed_message_intake / form_intake / indeed_fill_url /
-- checklist_overdue_check）は今回 anon 実行を残し、新Secret判定を必須にする（手順3・8）。
-- 1トランザクションで適用。実行場所: Supabase SQL Editor
-- =====================================================================
begin;
-- line-webhook内部（従業員LINE連携）
revoke all on function public.line_intake_user(text,text,text) from public, anon, authenticated;
grant execute on function public.line_intake_user(text,text,text) to service_role;
-- line-webhook内部（応募者LINE連携）
revoke all on function public.line_intake(text,text,text,text,timestamptz) from public, anon, authenticated;
grant execute on function public.line_intake(text,text,text,text,timestamptz) to service_role;
-- line-webhook内部（送信ログ）
revoke all on function public.line_log_out(text,uuid,text) from public, anon, authenticated;
grant execute on function public.line_log_out(text,uuid,text) to service_role;
-- line-webhook内部（面接リマインド印）
revoke all on function public.mark_interview_reminded(text,uuid) from public, anon, authenticated;
grant execute on function public.mark_interview_reminded(text,uuid) to service_role;
-- line-webhook内部（入社登録リマインド印）
revoke all on function public.recruit_mark_reminded(text,uuid) from public, anon, authenticated;
grant execute on function public.recruit_mark_reminded(text,uuid) to service_role;
-- line-webhook内部（毎日の点検対象）
revoke all on function public.recruit_daily_targets(text) from public, anon, authenticated;
grant execute on function public.recruit_daily_targets(text) to service_role;
-- CSV移行の取込口・呼び出し元なし
revoke all on function public.migrate_intake(text,text,text,text,text,text,timestamptz,timestamptz,text,jsonb,text) from public, anon, authenticated;
grant execute on function public.migrate_intake(text,text,text,text,text,text,timestamptz,timestamptz,text,jsonb,text) to service_role;
-- 合言葉チェック（E内部用）
revoke all on function public.checklist_intake_secret_ok(text) from public, anon, authenticated;
grant execute on function public.checklist_intake_secret_ok(text) to service_role;
-- 合言葉チェック（C・手順3で新設）
revoke all on function public.recruit_intake_secret_ok(text) from public, anon, authenticated;
grant execute on function public.recruit_intake_secret_ok(text) to service_role;
-- 合言葉チェック（D・手順3で新設）
revoke all on function public.checklist_alert_secret_ok(text) from public, anon, authenticated;
grant execute on function public.checklist_alert_secret_ok(text) to service_role;
commit;

-- 手順7 補足: GAS が直接呼ぶ採用RPC 4本から authenticated の実行権限を外す（画面からの呼び出し 0件・ユーザー指定の想定状態に合わせる）
begin;
revoke execute on function public.indeed_intake(text,text,text,text,text,text,text,timestamptz,text) from public, authenticated;
revoke execute on function public.indeed_message_intake(text,text,text,text,text,timestamptz) from public, authenticated;
revoke execute on function public.form_intake(text,text,text,text,jsonb,timestamptz,text) from public, authenticated;
revoke execute on function public.indeed_fill_url(text,text,text,text,timestamptz) from public, authenticated;
grant execute on function public.indeed_intake(text,text,text,text,text,text,text,timestamptz,text) to anon, service_role;
grant execute on function public.indeed_message_intake(text,text,text,text,text,timestamptz) to anon, service_role;
grant execute on function public.form_intake(text,text,text,text,jsonb,timestamptz,text) to anon, service_role;
grant execute on function public.indeed_fill_url(text,text,text,text,timestamptz) to anon, service_role;
commit;

-- 適用後の権限表（anon/authenticated が f、service_role が t、acl に =X/ が無いこと）
select p.proname, pg_get_function_identity_arguments(p.oid) as args,
       has_function_privilege('anon', p.oid, 'execute') as anon_ok,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_ok,
       has_function_privilege('service_role', p.oid, 'execute') as service_role_ok,
       coalesce(p.proacl::text, '(既定=PUBLIC実行可)') as acl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname in ('line_intake_user','line_intake','line_log_out','mark_interview_reminded','recruit_mark_reminded','recruit_daily_targets','migrate_intake','checklist_intake_secret_ok','recruit_intake_secret_ok','checklist_alert_secret_ok','indeed_intake','indeed_message_intake','form_intake','indeed_fill_url','checklist_overdue_check')
 order by 1, 2;
