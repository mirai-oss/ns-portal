-- 2026-11-26 Supabase警告(rls_disabled_in_public)対応
-- ログイン不要で読めていた14件を閉じる。ログイン済みのポータル/管理システム・サービスキーで動く取込は今まで通り動く。
-- 残す（意図的に公開: 申請フォーム・GAS・日報が公開キーで読む）: store_directory_v / cost_transfer_items_v / google_review_log_v / kd_sync_status_v / report_channel_matrix_v
-- テーブル: RLSを有効化＋ログイン済みユーザーには従来どおり全操作を許可するポリシーを追加（既にポリシーがあれば追加しない）＋anonの権限を外す
-- ビュー: anonの権限を外す
do $$
declare n text; k "char";
begin
  foreach n in array array[
    'ai_users_v','api_cost_daily','ar_deposits','ar_receivable_attachments','ar_receivables','ar_recurring_master',
    'cash_handoff_role_scope','google_review_legacy_compare_v','google_review_store_daily_v','import_status_today',
    'labor_allocation_compare_report','labor_salary_daily_weight','labor_salary_pay_type','sync_status_v']
  loop
    select c.relkind into k from pg_class c join pg_namespace s on s.oid=c.relnamespace
      where s.nspname='public' and c.relname=n;
    if k is null then continue; end if;
    if k in ('r','p') then
      execute format('alter table public.%I enable row level security', n);
      if not exists (select 1 from pg_policies where schemaname='public' and tablename=n) then
        execute format('create policy authenticated_full_access on public.%I for all to authenticated using (true) with check (true)', n);
      end if;
    end if;
    execute format('revoke all on public.%I from anon', n);
  end loop;
end $$;

-- 結果確認: 「まだRLSが無効のテーブル」と、anonが読めるかを一覧表示（残りの調査用）
select c.relname as table_name,
       has_table_privilege('anon', c.oid, 'select') as anon_can_read,
       has_table_privilege('anon', c.oid, 'insert,update,delete') as anon_can_write
from pg_class c join pg_namespace s on s.oid=c.relnamespace
where s.nspname='public' and c.relkind in ('r','p') and not c.relrowsecurity
order by anon_can_write desc, anon_can_read desc, 1;
