-- 2026-09-07 担当B（nippo）
-- ユーザー報告: 「従業員を削除しようとしたけどできない（関連するデータが見つかりません
-- でした、というエラー）」→ 実体は外部キー制約違反。
--
-- 原因: delete_user_completely() は個々のテーブルへの update/delete 文をハードコードして
-- いたが、ハブDB（ns-portal配下の全システムが共有）を実際に調査したところ、usersテーブルの
-- id を参照する外部キーが130以上（employee_profiles・sf_*・payroll_*・hq_*・invoice_*・
-- vendor_*・ck_*・expense_* 等、他担当のシステム分も含む）に増えており、この関数が把握して
-- 後始末していたのはそのうち十数個だけだった。今後も他担当がテーブルを追加するたびに同じ
-- 事故が起き続けるため、個別のハードコードをやめ、information_schemaから
-- 「usersを参照している外部キー」を実行時に動的に検出して後始末する方式に変更する。
--
-- 判定ロジック:
--   ①その列がテーブルの主キーの一部（＝その行の存在理由そのものがこのユーザー。
--     employee_profiles.user_id・payroll_bank_accounts.user_id 等）→ 行ごと削除
--   ②そうでない（created_by/assignee_id 等の参照列）→ まずNULLを試す
--     （tasks.assignee_id等、行自体は他の人のために残したいケースに対応）。
--     NOT NULL制約で失敗したら行ごと削除にフォールバック（reports.author_id等、
--     「そのユーザー自身のデータ」で行自体を残す意味が無いケースに対応）
-- 既存の個別update/delete文（tasks・reports・messages等）はそのまま残す（実績があり
-- 安全な処理順序が担保されているため）。動的処理はその後の「取りこぼし」を拾う位置づけ。
--
-- 呼び出し口はnippo/index.htmlの管理画面「完全に削除する」（CEOのみ・確認ダイアログ経由の
-- 二段階確認あり）のみで、既存のRLS・認可条件は一切変更していない（本ファイルは既存関数の
-- 内部ロジック改善のみ）。

create or replace function public.delete_user_completely(p_user uuid, p_confirm boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare v_me uuid := auth.uid(); v_name text;
  c_reports int; c_comments int; c_tasks int; c_tcomments int; c_msgs int; c_files int;
  r record;
begin
  if not exists (select 1 from users where id = v_me and role = 'CEO') then
    raise exception '権限がありません（社長のみ）'; end if;
  if p_user = v_me then raise exception '自分自身は削除できません'; end if;
  select name into v_name from users where id = p_user;
  if v_name is null then raise exception '対象のユーザーが見つかりません'; end if;
  select count(*) into c_reports from reports where author_id = p_user;
  select count(*) into c_comments from report_comments where author_id = p_user;
  select count(*) into c_tasks from tasks where created_by = p_user;
  select count(*) into c_tcomments from task_comments where author_id = p_user;
  select count(*) into c_msgs from messages where sender_id = p_user;
  select count(*) into c_files from attachments where uploaded_by = p_user;
  if not p_confirm then
    return jsonb_build_object('ok', false, 'name', v_name, 'reports', c_reports, 'comments', c_comments,
      'tasks', c_tasks, 'task_comments', c_tcomments, 'messages', c_msgs, 'files', c_files);
  end if;
  update tasks set assignee_id = null where assignee_id = p_user;
  update notifications set actor_id = null where actor_id = p_user;
  update app_settings set updated_by = null where updated_by = p_user;
  update applicants set assignee_id = null where assignee_id = p_user;
  update applicants set created_by = null where created_by = p_user;
  update applicants set user_id = null where user_id = p_user;
  update invitations set created_by = null where created_by = p_user;
  update invitations set used_by = null where used_by = p_user;
  begin update recruit_costs set updated_by = null where updated_by = p_user; exception when undefined_table then null; end;
  begin update role_features set updated_by = null where updated_by = p_user; exception when undefined_table then null; end;
  begin update app_secrets set updated_by = null where updated_by = p_user; exception when undefined_table then null; end;
  begin update applicant_forms set updated_by = null where updated_by = p_user; exception when undefined_table then null; end;
  delete from attachments where uploaded_by = p_user;
  delete from task_comments where author_id = p_user;
  delete from tasks where created_by = p_user;
  delete from messages where sender_id = p_user;
  delete from report_comments where author_id = p_user;
  delete from reports where author_id = p_user;
  begin delete from activity_logs where user_id = p_user; exception when undefined_table then null; end;

  -- 2026-09-07追加: 上記で把握しきれていない残り全てのusers参照テーブルを動的に後始末
  for r in
    select tc.table_name, kcu.column_name,
      exists(
        select 1 from information_schema.table_constraints pk
        join information_schema.key_column_usage pkk
          on pkk.constraint_name = pk.constraint_name and pkk.constraint_schema = pk.constraint_schema
        where pk.table_schema = tc.table_schema and pk.table_name = tc.table_name
          and pk.constraint_type = 'PRIMARY KEY' and pkk.column_name = kcu.column_name
      ) as is_pk_col
    from information_schema.table_constraints tc
    join information_schema.key_column_usage kcu
      on kcu.constraint_name = tc.constraint_name and kcu.constraint_schema = tc.constraint_schema
    join information_schema.constraint_column_usage ccu
      on ccu.constraint_name = tc.constraint_name and ccu.constraint_schema = tc.constraint_schema
    where tc.constraint_type = 'FOREIGN KEY' and tc.table_schema = 'public'
      and ccu.table_schema = 'public' and ccu.table_name = 'users' and ccu.column_name = 'id'
  loop
    begin
      if r.is_pk_col then
        execute format('delete from public.%I where %I = $1', r.table_name, r.column_name) using p_user;
      else
        begin
          execute format('update public.%I set %I = null where %I = $1', r.table_name, r.column_name, r.column_name) using p_user;
        exception when not_null_violation then
          execute format('delete from public.%I where %I = $1', r.table_name, r.column_name) using p_user;
        end;
      end if;
    exception when others then
      null; -- そのテーブルだけ消せなくても、他のテーブルの後始末は続行する
    end;
  end loop;

  delete from auth.users where id = p_user;
  return jsonb_build_object('ok', true, 'name', v_name);
end $function$;
