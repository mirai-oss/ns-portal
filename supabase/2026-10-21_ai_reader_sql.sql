-- 2026-10-21: AI窓口（Hermes）が「管理システムに入っているデータは基本すべて答えられる」ようにする基盤
-- ユーザー指示「基本的に管理システムに入っているデータは、全て回答できるような状態に設計してほしい」
-- 要件定義書§18（AIはRead Only・service_roleを渡さない・ホワイトリスト経由・監査ログ）を守ったまま、
-- 固定カタログ7本 → 「許可テーブルに対する読み取り専用SQL」へ拡張する。
--
-- 仕組み:
--   1. DBロール ai_reader（ログイン不可）を作り、public の許可テーブルにだけ SELECT を付与する
--   2. どのテーブルを許可するかは ai_table_policy で管理（deny=機密: 秘密鍵・給与・口座・個人情報・私信）
--      ai_reader_sync() を実行すると、policy に従って GRANT/REVOKE を揃える（新テーブルは「未判定=拒否」）
--   3. RPC ai_sql(p_sql) は security definer だが、中で SET LOCAL ROLE ai_reader に降格してから実行する
--      → ai_reader に無い権限では読めない。SELECT/WITH 以外・複文・8秒超・500行超は拒否/打ち切り
--   4. RPC ai_schema() が許可テーブルと列・説明を返す（AIはこれを見てSQLを組み立てる）
--   5. 呼び出しは ai-gateway Edge Function（service_role）経由のみ。anon/authenticated からは実行不可
-- info スキーマ（社内情報管理システム=ID/PW・契約・給与体系）は対象外（権限を一切付与しない）

-- ---------- 1. ロール ----------
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'ai_reader') then
    create role ai_reader nologin;
  end if;
end $$;
revoke all on schema public from ai_reader;
grant usage on schema public to ai_reader;
-- 念のため: 他スキーマは触らせない
revoke all on all tables in schema public from ai_reader;

-- ---------- 2. 許可/拒否ポリシー ----------
create table if not exists ai_table_policy (
  table_name   text primary key,
  allowed      boolean not null,
  reason       text,                 -- 拒否理由／用途メモ
  description  text,                 -- AIに見せる日本語の説明（何のテーブルか）
  updated_at   timestamptz not null default now()
);
alter table ai_table_policy enable row level security;
drop policy if exists ai_table_policy_master_read on ai_table_policy;
create policy ai_table_policy_master_read on ai_table_policy for select to authenticated using (portal_is_master());

-- 拒否リスト（機密・個人情報・秘密鍵・私信）。ここに無いテーブルは下の sync で「許可」になる
insert into ai_table_policy(table_name, allowed, reason) values
  -- 秘密鍵・トークン
  ('app_secrets', false, '秘密鍵'), ('mf_oauth_tokens', false, 'トークン'), ('infomart_oauth_tokens', false, 'トークン'),
  ('indeed_own_keys', false, 'トークン'), ('hr_form_tokens', false, 'トークン'), ('ds_sessions', false, 'セッション'),
  ('invitations', false, '招待トークン'), ('smaregi_contracts', false, '契約ID・認証情報'),
  -- 給与・人件費の個人別
  ('sf_payroll_sync', false, '給与(個人別)'), ('sf_payroll_allocations', false, '給与(個人別)'), ('sf_payroll_hidden', false, '給与'),
  ('payroll_bank_accounts', false, '従業員口座'), ('payroll_bulk_runs', false, '給与'), ('payroll_journal_assignments', false, '給与'),
  ('payroll_journal_drafts', false, '給与'), ('payroll_journal_records', false, '給与'), ('payroll_kind_overrides', false, '給与'),
  ('payroll_task_links', false, '給与'), ('payroll_transfer_schedule', false, '給与'),
  ('employee_wage_settings', false, '時給・固定給(個人別)'), ('hr_wage_requests', false, '昇給申請'), ('hr_wage_pending_confirm', false, '昇給'),
  ('hr_wage_request_msgs', false, '昇給'), ('labor_salary_daily_weight', false, '給与按分(個人別)'), ('labor_salary_pay_type', false, '給与'),
  ('sf_paid_leave_grants', false, '有給(個人別)'), ('sf_paid_leave_requests', false, '有給(個人別)'),
  ('sf_cash_handoff_signatures', false, '現金手渡し署名'), ('cash_handoff_role_scope', false, '現金手渡し'),
  -- 口座（取引先・自社）
  ('vendor_bank_accounts', false, '取引先口座'), ('vendor_bank_account_change_requests', false, '取引先口座'),
  -- 個人情報（従業員・応募者）・私信
  ('employee_profiles', false, '住所・生年月日等'), ('hr_documents', false, '労務書類'), ('hr_change_requests', false, '個人情報変更申請'),
  ('profile_change_requests', false, '個人情報変更申請'),
  ('applicants', false, '応募者個人情報'), ('applicant_forms', false, '応募者'), ('applicant_messages', false, '応募者'),
  ('applicant_merges', false, '応募者'), ('applicant_not_same', false, '応募者'), ('applicant_reads', false, '応募者'),
  ('messages', false, 'チャット私信'), ('chat_rooms', false, 'チャット'), ('room_members', false, 'チャット'), ('message_likes', false, 'チャット'),
  ('attachments', false, '添付(パス)'), ('invoice_emails', false, 'メール本文'), ('invoice_email_outbox', false, 'メール'),
  ('invoice_email_reads', false, 'メール'), ('user_stores_backup_20261017', false, 'バックアップ'),
  -- users は列を絞ったビューで出す（下）
  ('users', false, 'ビュー ai_users_v で公開（氏名・役割・所属のみ）')
on conflict (table_name) do nothing;

-- users の公開用ビュー（連絡先・認証系の列を含めない）
create or replace view ai_users_v with (security_invoker = false) as
  select u.id, u.name, u.role, u.is_active, u.is_master,
         (select string_agg(s.name, '・' order by s.store_no) from user_stores us join stores s on s.id = us.store_id where us.user_id = u.id) as stores
  from users u;
insert into ai_table_policy(table_name, allowed, description) values ('ai_users_v', true, 'ポータル利用者（氏名・役割・所属店舗のみ）') on conflict (table_name) do update set allowed = true, description = excluded.description;

-- 主要テーブルの日本語説明（AIが選びやすいように。無いテーブルは pg の comment or 名前のみ）
insert into ai_table_policy(table_name, allowed, description) values
  ('stores', true, '店舗マスタ（store_no=店舗番号01〜12・name=正式名・signs=看板・corporation_id=法人）'),
  ('store_aliases', true, '店舗名の表記ゆれ（alias→store_id）'),
  ('corporations', true, '法人マスタ（corp_code: toho/nstyle/sk/livegate）'),
  ('dash_sales_daily', true, '店舗×日の売上(sales)・原価(cost)・人件費(labor)。biz_date=営業日。2024-07〜。当日行は0のことがある'),
  ('dash_sales_target_daily', true, '店舗×日の売上目標'), ('dash_target_monthly', true, '店舗×月の売上目標'),
  ('kd_pl_monthly_summary', true, '店舗×年月のPL（売上・原価・人件費・広告費・家賃・粗利・営業利益）'),
  ('kd_media_monthly_summary', true, '店舗×年月×媒体（食べログ等）の売上・客数・組数'),
  ('kd_media_daily', true, '店舗×日×媒体の売上・客数'),
  ('kd_deposit_monthly_summary', true, '店舗×年月の入金（カード・PayPay等）'),
  ('kd_reservation_daily_summary', true, '店舗×日の予約件数・人数・キャンセル'),
  ('kd_detail_item_daily', true, '店舗×日×商品の販売数・売上（レジ明細）'),
  ('kd_detail_hour_daily', true, '店舗×日×時間帯の売上・客数'),
  ('kd_ad_monthly', true, '店舗×年月×媒体の広告費'),
  ('reports', true, '日報・週報（kind=daily/weekly・report_date・author_id→ai_users_v.id・store_id）'),
  ('hq_tasks', true, '本部タスク（title・status・due_date・store_id・assignee）'), ('hq_task_steps', true, '本部タスクの工程'),
  ('checklist_templates', true, '店舗チェックシートのテンプレ'), ('checklist_checks', true, 'チェック実施記録（work_date・store_id・item_id）'),
  ('checklist_overdue_alerts', true, 'チェック未実施アラート'),
  ('expense_requests', true, '経費申請（金額・状態・申請者・店舗）'), ('expense_categories', true, '経費科目'),
  ('invoices', true, '請求書（取引先・金額・支払期日・処理状態）'), ('invoice_lines', true, '請求書明細'),
  ('vendors', true, '取引先マスタ（会計用）'), ('ar_receivables', true, '売上入金の債権（カード・PayPay等の入金予定/実績・手数料）'),
  ('import_runs', true, '自動取込ジョブの実行履歴（成功/失敗）'), ('import_schedule', true, '自動取込ジョブの予定'),
  ('sf_shifts', true, 'シフト（店舗×日×人・時間帯）'), ('attendance_records', true, '勤怠打刻（スマレジ由来・個人別の出退勤）'),
  ('labor_cost_daily', true, '店舗×日の人件費'), ('rsv_reservations', true, '予約明細'),
  ('portal_posts', true, '社内お知らせ（掲示板）'), ('tasks', true, 'nippoのタスク'), ('manual_items', true, 'マニュアル'),
  ('account_items', true, '勘定科目マスタ'), ('pl_entries', true, 'PL手入力明細'), ('recruit_costs', true, '採用費'),
  ('job_postings', true, '求人原稿'), ('ai_audit_logs', true, 'AI窓口の照会ログ')
on conflict (table_name) do update set description = excluded.description;

-- ---------- 3. GRANT同期 ----------
create or replace function ai_reader_sync()
returns table(table_name text, allowed boolean, action text)
language plpgsql security definer set search_path = public as $$
declare r record; v_allowed boolean;
begin
  for r in
    select c.relname as tname, c.relkind
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r','v','m','p') and c.relname not like 'pg_%'
  loop
    select p.allowed into v_allowed from ai_table_policy p where p.table_name = r.tname;
    if v_allowed is null then
      -- 未判定の新テーブル: 既定は「拒否」。許可するには ai_table_policy に allowed=true を入れて再実行
      insert into ai_table_policy(table_name, allowed, reason) values (r.tname, false, '未判定（新規テーブル・既定は拒否）') on conflict do nothing;
      v_allowed := false;
    end if;
    if v_allowed then
      execute format('grant select on %I to ai_reader', r.tname);
      table_name := r.tname; allowed := true; action := 'grant'; return next;
    else
      execute format('revoke all on %I from ai_reader', r.tname);
      table_name := r.tname; allowed := false; action := 'revoke'; return next;
    end if;
  end loop;
end $$;
revoke all on function ai_reader_sync() from public, anon, authenticated;

-- 既存テーブルで policy に無いものは「許可」として初期登録（ユーザー方針「基本すべて答えられる」。
-- 以後に作られる新テーブルは上の sync で「未判定=拒否」になる）
insert into ai_table_policy(table_name, allowed, reason)
select c.relname, true, '初期一括許可(2026-10-21)'
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r','v','m','p') and c.relname not like 'pg_%'
on conflict (table_name) do nothing;
select count(*) filter (where allowed) as granted, count(*) filter (where not allowed) as revoked from ai_reader_sync();

-- ---------- 4. 読み取り専用SQL ----------
create or replace function ai_sql(p_sql text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_sql text; v_rows jsonb; v_count int;
begin
  v_sql := btrim(coalesce(p_sql, ''));
  v_sql := regexp_replace(v_sql, ';\s*$', '');
  if v_sql = '' then raise exception 'SQLが空です'; end if;
  if v_sql ~* '^\s*(select|with)\b' is not true then raise exception 'SELECT / WITH で始まる読み取り専用SQLだけ実行できます'; end if;
  if position(';' in v_sql) > 0 then raise exception '複数の文は実行できません（; を含めない）'; end if;
  if v_sql ~* '\m(insert|update|delete|truncate|drop|alter|create|grant|revoke|copy|call|do|vacuum|analyze|refresh|lock|set|reset|pg_sleep|pg_read|lo_|dblink)\M' then
    raise exception '読み取り以外の命令が含まれています';
  end if;
  -- 権限を ai_reader に降格（security definer の権限では実行しない）
  execute 'set local role ai_reader';
  execute 'set local statement_timeout = ''8000''';
  execute 'set local search_path = public';
  execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb), count(*) from (%s) t', v_sql) into v_rows, v_count;
  if v_count > 500 then
    execute format('select coalesce(jsonb_agg(t), ''[]''::jsonb) from (select * from (%s) q limit 500) t', v_sql) into v_rows;
  end if;
  return jsonb_build_object('rows', v_rows, 'row_count', least(v_count, 500), 'total_count', v_count, 'truncated', v_count > 500);
end $$;
revoke all on function ai_sql(text) from public, anon, authenticated;

-- ---------- 5. スキーマ案内 ----------
create or replace function ai_schema(p_table text default null)
returns jsonb
language sql security definer set search_path = public stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'table', t.table_name,
           'description', coalesce(p.description, obj_description(('public.'||quote_ident(t.table_name))::regclass, 'pg_class')),
           'columns', (select jsonb_agg(jsonb_build_object('name', c.column_name, 'type', c.data_type,
                           'comment', col_description(('public.'||quote_ident(t.table_name))::regclass, c.ordinal_position)) order by c.ordinal_position)
                       from information_schema.columns c where c.table_schema = 'public' and c.table_name = t.table_name)
         ) order by t.table_name), '[]'::jsonb)
  from information_schema.tables t join ai_table_policy p on p.table_name = t.table_name and p.allowed
  where t.table_schema = 'public' and (p_table is null or t.table_name = p_table)
    and has_table_privilege('ai_reader', 'public.'||quote_ident(t.table_name), 'select');
$$;
revoke all on function ai_schema(text) from public, anon, authenticated;

-- ---------- 6. 便利RPC: 日別・店舗別売上 ----------
create or replace function ai_sales_daily(p_date date default null, p_store text default null)
returns jsonb language sql security definer set search_path = public stable as $$
  with d as (select coalesce(p_date, (now() at time zone 'Asia/Tokyo')::date - 1) as dt),
  cur as (
    select s.store_no, s.name, x.sales, x.cost, x.labor
    from dash_sales_daily x join stores s on s.id = x.store_id, d
    where x.biz_date = d.dt and (p_store is null or s.name like '%'||p_store||'%' or s.store_no = p_store)
  ),
  ly as (
    select s.store_no, x.sales
    from dash_sales_daily x join stores s on s.id = x.store_id, d
    where x.biz_date = d.dt - interval '364 days'  -- 前年の同じ曜日
  )
  select jsonb_build_object(
    'date', (select dt from d),
    'weekday', to_char((select dt from d), 'Dy'),
    'total_sales', (select coalesce(sum(sales),0) from cur),
    'last_year_same_weekday_total', (select coalesce(sum(sales),0) from ly),
    'by_store', (select coalesce(jsonb_agg(jsonb_build_object('store_no', c.store_no, 'store', c.name, 'sales', c.sales, 'cost', c.cost, 'labor', round(c.labor),
                        'last_year_same_weekday', l.sales) order by c.store_no), '[]'::jsonb)
                 from cur c left join ly l on l.store_no = c.store_no)
  );
$$;
revoke all on function ai_sales_daily(date, text) from public, anon, authenticated;

-- 確認用:
-- select ai_schema('dash_sales_daily');
-- select ai_sql('select s.name, x.sales from dash_sales_daily x join stores s on s.id=x.store_id where x.biz_date = current_date - 1 order by s.store_no');
-- select ai_sql('delete from stores');            -- → エラー（読み取り以外）
-- select ai_sql('select * from sf_payroll_sync');  -- → permission denied（ai_reader に権限なし）
