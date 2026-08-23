-- ============================================================
-- 請求書メール管理 Phase 1（MVP）
-- 指示書: docs/実装指示書_請求書メール管理Phase1_2026-08-23.md
-- 画面=invoices.html（新規）／データ=ハブ。既存テーブルは無変更。
-- 冪等。二重処理防止はDBレベル（invoice_start_processingのwhere句が本体、
-- UIだけの防止にしない＝指示書§7の禁止事項）。
-- ============================================================

-- ---- メール本体 ----
create table if not exists invoice_emails (
  id uuid primary key default gen_random_uuid(),
  gmail_message_id text not null unique,
  gmail_thread_id text,
  oauth_parent_account text not null default 'shunji.nakayama@ns0314.com',
  target_alias text not null default 'info@ns0314.com',
  from_address text,
  to_address text,
  delivered_to text,
  cc_address text,
  subject text,
  body_text text,
  body_html text,
  received_at timestamptz,
  mail_status text not null default 'unread' check (mail_status in ('unread','read','processing','completed','archived')),
  processing_user_id uuid references users(id),
  processing_started_at timestamptz,
  locked_at timestamptz,
  lock_expires_at timestamptz,
  lock_released_by uuid references users(id),
  lock_released_at timestamptz,
  lock_release_reason text,
  completed_by uuid references users(id),
  completed_at timestamptz,
  completion_note text,
  duplicate_suspected boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists invoice_emails_status_idx on invoice_emails (mail_status, received_at desc);
create index if not exists invoice_emails_received_idx on invoice_emails (received_at desc);

-- ---- 開封履歴（毎回insert=履歴として全部残す。unique制約は付けない） ----
create table if not exists invoice_email_reads (
  id uuid primary key default gen_random_uuid(),
  email_id uuid not null references invoice_emails(id) on delete cascade,
  user_id uuid not null references users(id),
  opened_at timestamptz not null default now()
);
create index if not exists invoice_email_reads_email_idx on invoice_email_reads (email_id, opened_at desc);

-- ---- 添付 ----
create table if not exists invoice_attachments (
  id uuid primary key default gen_random_uuid(),
  email_id uuid not null references invoice_emails(id) on delete cascade,
  file_name text not null,
  mime_type text,
  storage_path text not null,
  file_hash text not null,
  size_bytes bigint,
  created_at timestamptz not null default now()
);
create index if not exists invoice_attachments_email_idx on invoice_attachments (email_id);
create index if not exists invoice_attachments_hash_idx on invoice_attachments (file_hash);

-- ---- 請求書エンティティ（Phase1は手入力任意。OCRはPhase3用の器） ----
create table if not exists invoices (
  id uuid primary key default gen_random_uuid(),
  email_id uuid references invoice_emails(id) on delete cascade,
  attachment_id uuid references invoice_attachments(id),
  vendor_name text,
  invoice_number text,
  amount numeric(12,0),
  due_date date,
  invoice_status text not null default 'draft' check (invoice_status in ('draft','registered','duplicate_suspected','waiting_payment','paid','cancelled')),
  assigned_user_id uuid references users(id),
  duplicate_suspected boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists invoices_email_idx on invoices (email_id);

-- ---- 監査ログ（取込/開封/担当/ロック解除/完了/状態変更/重複警告/返信すべて） ----
create table if not exists invoice_audit_logs (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null,
  entity_id uuid,
  action text not null,
  user_id uuid references users(id),
  actor_type text not null default 'human' check (actor_type in ('human','ai')),
  old_value jsonb,
  new_value jsonb,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists invoice_audit_logs_entity_idx on invoice_audit_logs (entity_type, entity_id, created_at desc);

-- ---- 返信outbox（指示書§4.5・2026-08-23確定） ----
create table if not exists invoice_email_outbox (
  id uuid primary key default gen_random_uuid(),
  email_id uuid not null references invoice_emails(id),
  body_text text not null,
  status text not null default 'queued' check (status in ('queued','sent','failed')),
  queued_by uuid references users(id),
  queued_at timestamptz not null default now(),
  sent_at timestamptz,
  gmail_sent_message_id text,
  error text
);
create index if not exists invoice_email_outbox_status_idx on invoice_email_outbox (status, queued_at);

-- ============================================================
-- 権限判定関数
-- 指示書§2: role in ('CEO','HQ') or is_master、＋portal_user_overrides(system_key='invoices')で個人単位に追加開放
-- ============================================================
create or replace function invoice_can_access() returns boolean
language sql stable security definer set search_path = public as $$
  select
    coalesce((select u.is_master or u.role in ('CEO','HQ') from users u where u.id = auth.uid() and u.is_active), false)
    or coalesce((select po.allowed from portal_user_overrides po where po.user_id = auth.uid() and po.system_key = 'invoices'), false);
$$;

-- ============================================================
-- 共有シークレット（GAS invoice-intake ↔ Edge Function invoice-intake/invoice-send）
-- 値は毎回ランダム生成しapp_secretsのみに保存。コード上には一切書かない
-- （2026-08-21のINTAKE_SECRET平文露出事故=R6の再発防止。取得は別途
--  `select value from app_secrets where key='invoice_intake_secret'` を1回実行し、
--  Edge Function環境変数・GAS Script Propertiesへ手動転記して終わる）
-- ============================================================
insert into app_secrets (key, value, updated_at)
select 'invoice_intake_secret', encode(gen_random_bytes(24), 'hex'), now()
where not exists (select 1 from app_secrets where key = 'invoice_intake_secret');

create or replace function invoice_intake_secret_ok(p_secret text) returns boolean
language sql stable security definer set search_path = public as $$
  select p_secret is not null and p_secret = (select value from app_secrets where key = 'invoice_intake_secret');
$$;

-- ============================================================
-- RLS（直接INSERT/UPDATEは不可。全操作RPC経由。invoicesの手入力欄のみ直接編集を許可＝指示書§4の任意項目）
-- ============================================================
alter table invoice_emails enable row level security;
alter table invoice_email_reads enable row level security;
alter table invoice_attachments enable row level security;
alter table invoices enable row level security;
alter table invoice_audit_logs enable row level security;
alter table invoice_email_outbox enable row level security;

drop policy if exists inv_emails_read on invoice_emails;
create policy inv_emails_read on invoice_emails for select using (invoice_can_access());

drop policy if exists inv_reads_read on invoice_email_reads;
create policy inv_reads_read on invoice_email_reads for select using (invoice_can_access());

drop policy if exists inv_attach_read on invoice_attachments;
create policy inv_attach_read on invoice_attachments for select using (invoice_can_access());

drop policy if exists inv_invoices_read on invoices;
create policy inv_invoices_read on invoices for select using (invoice_can_access());
drop policy if exists inv_invoices_insert on invoices;
create policy inv_invoices_insert on invoices for insert with check (invoice_can_access());
drop policy if exists inv_invoices_update on invoices;
create policy inv_invoices_update on invoices for update using (invoice_can_access()) with check (invoice_can_access());

drop policy if exists inv_audit_read on invoice_audit_logs;
create policy inv_audit_read on invoice_audit_logs for select using (invoice_can_access());

drop policy if exists inv_outbox_read on invoice_email_outbox;
create policy inv_outbox_read on invoice_email_outbox for select using (invoice_can_access());
-- insertはinvoice_queue_reply経由のみ。updateはinvoice-send Edge Function(service_role)のみ＝直接policyなし

-- ============================================================
-- 処理フロー RPC（すべてsecurity definer・invoice_audit_logsへ記録）
-- ============================================================

-- 処理開始（担当ロック）: 二重処理防止の本体。同時に2人が押しても1人しか成功しない
create or replace function invoice_start_processing(p_email_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_updated invoice_emails; v_holder text;
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;

  update invoice_emails set
    processing_user_id = auth.uid(),
    processing_started_at = now(),
    locked_at = now(),
    lock_expires_at = now() + interval '24 hours',
    mail_status = 'processing',
    updated_at = now()
  where id = p_email_id
    and (processing_user_id is null or lock_expires_at < now())
  returning * into v_updated;

  if v_updated.id is not null then
    insert into invoice_audit_logs(entity_type, entity_id, action, user_id, new_value)
    values ('invoice_email', p_email_id, 'start_processing', auth.uid(), jsonb_build_object('mail_status','processing'));
    return jsonb_build_object('success', true);
  end if;

  select u.name into v_holder from invoice_emails e join users u on u.id = e.processing_user_id where e.id = p_email_id;
  return jsonb_build_object('success', false, 'held_by', v_holder);
end;
$$;

-- ロック解除（本人／portal_is_master()／invoice_can_access()のいずれか・理由必須）
create or replace function invoice_release_lock(p_email_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email invoice_emails; v_is_holder boolean;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception '解除理由を入力してください';
  end if;
  select * into v_email from invoice_emails where id = p_email_id;
  if v_email is null then raise exception '対象が見つかりません'; end if;
  v_is_holder := (v_email.processing_user_id = auth.uid());
  if not (v_is_holder or portal_is_master() or invoice_can_access()) then
    raise exception 'この操作を行う権限がありません';
  end if;

  update invoice_emails set
    processing_user_id = null,
    processing_started_at = null,
    locked_at = null,
    lock_expires_at = null,
    lock_released_by = auth.uid(),
    lock_released_at = now(),
    lock_release_reason = p_reason,
    mail_status = case when mail_status = 'processing' then 'unread' else mail_status end,
    updated_at = now()
  where id = p_email_id;

  insert into invoice_audit_logs(entity_type, entity_id, action, user_id, old_value, note)
  values ('invoice_email', p_email_id, 'release_lock', auth.uid(),
          jsonb_build_object('processing_user_id', v_email.processing_user_id), p_reason);

  return jsonb_build_object('success', true);
end;
$$;

-- 処理完了（担当者本人のみ・メモ任意）
create or replace function invoice_complete(p_email_id uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_email invoice_emails;
begin
  select * into v_email from invoice_emails where id = p_email_id;
  if v_email is null then raise exception '対象が見つかりません'; end if;
  if v_email.processing_user_id is distinct from auth.uid() then
    raise exception '処理中の担当者本人のみ完了できます';
  end if;

  update invoice_emails set
    mail_status = 'completed', completed_by = auth.uid(), completed_at = now(),
    completion_note = p_note, updated_at = now()
  where id = p_email_id;

  insert into invoice_audit_logs(entity_type, entity_id, action, user_id, note)
  values ('invoice_email', p_email_id, 'complete', auth.uid(), p_note);

  return jsonb_build_object('success', true);
end;
$$;

-- 開封記録（詳細を開いたら自動insert）
create or replace function invoice_record_read(p_email_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  if not exists(select 1 from invoice_emails where id = p_email_id) then raise exception '対象が見つかりません'; end if;

  insert into invoice_email_reads(email_id, user_id) values (p_email_id, auth.uid());
  update invoice_emails set mail_status = 'read', updated_at = now()
   where id = p_email_id and mail_status = 'unread';

  insert into invoice_audit_logs(entity_type, entity_id, action, user_id)
  values ('invoice_email', p_email_id, 'open', auth.uid());

  return jsonb_build_object('success', true);
end;
$$;

-- 一括操作（2026-08-24追加）: 過去分の未処理メールをまとめて処理したいという要望に対応。
-- p_action='start'   : まとめて処理開始（既に他の人がロック中のものはスキップ）
-- p_action='complete': まとめて完了（他の人がロック中のものはスキップ。未処理のものは自分が
--                       処理したことにして完了＝バックログの一括消化を想定。既に完了済みはスキップ）
-- p_action='waiting_payment': invoicesの状態を「支払待ち」に設定（無ければ新規作成）。
--                       mail_status（処理中/完了）とは独立して使える
create or replace function invoice_bulk_action(p_email_ids uuid[], p_action text, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_email invoice_emails; v_success int := 0; v_skipped jsonb := '[]'::jsonb; v_holder text;
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  if p_action not in ('start','complete','waiting_payment') then raise exception '不正なアクションです'; end if;

  foreach v_id in array p_email_ids loop
    select * into v_email from invoice_emails where id = v_id;
    if v_email is null then
      v_skipped := v_skipped || jsonb_build_object('id', v_id, 'reason', '対象が見つかりません');
      continue;
    end if;

    if p_action = 'start' then
      if v_email.processing_user_id is not null and v_email.lock_expires_at > now() then
        select u.name into v_holder from users u where u.id = v_email.processing_user_id;
        v_skipped := v_skipped || jsonb_build_object('id', v_id, 'reason', coalesce(v_holder,'他の人') || 'さんが処理中');
        continue;
      end if;
      update invoice_emails set
        processing_user_id = auth.uid(), processing_started_at = now(),
        locked_at = now(), lock_expires_at = now() + interval '24 hours',
        mail_status = 'processing', updated_at = now()
      where id = v_id;
      insert into invoice_audit_logs(entity_type, entity_id, action, user_id, note)
      values ('invoice_email', v_id, 'start_processing', auth.uid(), coalesce(p_note, '一括処理'));
      v_success := v_success + 1;

    elsif p_action = 'complete' then
      if v_email.mail_status = 'completed' then
        v_skipped := v_skipped || jsonb_build_object('id', v_id, 'reason', '既に完了済み');
        continue;
      end if;
      if v_email.processing_user_id is not null and v_email.processing_user_id <> auth.uid() and v_email.lock_expires_at > now() then
        select u.name into v_holder from users u where u.id = v_email.processing_user_id;
        v_skipped := v_skipped || jsonb_build_object('id', v_id, 'reason', coalesce(v_holder,'他の人') || 'さんが処理中のためスキップ');
        continue;
      end if;
      update invoice_emails set
        processing_user_id = coalesce(v_email.processing_user_id, auth.uid()),
        mail_status = 'completed', completed_by = auth.uid(), completed_at = now(),
        completion_note = coalesce(p_note, completion_note), updated_at = now()
      where id = v_id;
      insert into invoice_audit_logs(entity_type, entity_id, action, user_id, note)
      values ('invoice_email', v_id, 'complete', auth.uid(), coalesce(p_note, '一括処理'));
      v_success := v_success + 1;

    elsif p_action = 'waiting_payment' then
      if exists(select 1 from invoices where email_id = v_id) then
        update invoices set invoice_status = 'waiting_payment', assigned_user_id = auth.uid(), updated_at = now() where email_id = v_id;
      else
        insert into invoices(email_id, invoice_status, assigned_user_id) values (v_id, 'waiting_payment', auth.uid());
      end if;
      insert into invoice_audit_logs(entity_type, entity_id, action, user_id, note)
      values ('invoice_email', v_id, 'invoice_status_set', auth.uid(), '支払待ちに設定（一括）');
      v_success := v_success + 1;
    end if;
  end loop;

  return jsonb_build_object('success_count', v_success, 'skipped', v_skipped);
end;
$$;

-- 手動添付の登録（2026-08-24追加）: ダウンロードリンク＋パスワード式など、メールに直接
-- 添付されていない請求書をユーザーがダウンロードして手動でアップロードした場合に、その
-- ファイルをメールへ紐付ける。ファイル本体はクライアントが自分のJWTでstorageへ直接
-- アップロード（storage.objectsのinsert policyで許可）し、このRPCはメタデータ登録＋監査ログのみ
create or replace function invoice_attach_manual_file(
  p_email_id uuid, p_file_name text, p_mime_type text, p_storage_path text, p_file_hash text, p_size_bytes bigint
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_attachment_id uuid; v_dup boolean;
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  if not exists(select 1 from invoice_emails where id = p_email_id) then raise exception '対象が見つかりません'; end if;

  insert into invoice_attachments(email_id, file_name, mime_type, storage_path, file_hash, size_bytes)
  values (p_email_id, p_file_name, p_mime_type, p_storage_path, p_file_hash, p_size_bytes)
  returning id into v_attachment_id;

  select exists(select 1 from invoice_attachments where file_hash = p_file_hash and id <> v_attachment_id) into v_dup;
  if v_dup then
    update invoice_emails set duplicate_suspected = true where id = p_email_id;
  end if;

  insert into invoice_audit_logs(entity_type, entity_id, action, user_id, note)
  values ('invoice_email', p_email_id, 'manual_attach', auth.uid(), p_file_name);

  return v_attachment_id;
end;
$$;

-- 返信キュー投入（処理権限者のみ。実送信はinvoice-send Edge Functionが担当）
create or replace function invoice_queue_reply(p_email_id uuid, p_body text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_outbox_id uuid;
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  if p_body is null or length(trim(p_body)) = 0 then raise exception '本文を入力してください'; end if;
  if not exists(select 1 from invoice_emails where id = p_email_id) then raise exception '対象が見つかりません'; end if;

  insert into invoice_email_outbox(email_id, body_text, status, queued_by)
  values (p_email_id, p_body, 'queued', auth.uid())
  returning id into v_outbox_id;

  insert into invoice_audit_logs(entity_type, entity_id, action, user_id, note)
  values ('invoice_email_outbox', v_outbox_id, 'reply_queued', auth.uid(), left(p_body, 500));

  return v_outbox_id;
end;
$$;

-- ============================================================
-- 返信送信 RPC群（GAS側の5分トリガー保険ルートが使う。invoice_intake_secretで認証。
-- 即時ルート＝Edge Function invoice-send はservice_roleで直接outboxを更新するためRPC不要）
-- ============================================================

-- 未送信(queued)を取得（GASの5分トリガーが拾う）
create or replace function invoice_outbox_pull_queued(p_secret text) returns setof invoice_email_outbox
language plpgsql stable security definer set search_path = public as $$
begin
  if not invoice_intake_secret_ok(p_secret) then raise exception '認証エラー'; end if;
  return query select * from invoice_email_outbox where status = 'queued' order by queued_at limit 20;
end;
$$;

-- 送信成功をoutboxへ書き戻し。監査ログにaction='reply_sent'で本文込み記録（指示書§4.5）
create or replace function invoice_outbox_mark_sent(p_secret text, p_outbox_id uuid, p_gmail_sent_message_id text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ob invoice_email_outbox;
begin
  if not invoice_intake_secret_ok(p_secret) then raise exception '認証エラー'; end if;
  update invoice_email_outbox set status = 'sent', sent_at = now(), gmail_sent_message_id = p_gmail_sent_message_id
   where id = p_outbox_id returning * into v_ob;
  if v_ob.id is null then raise exception '対象が見つかりません'; end if;

  insert into invoice_audit_logs(entity_type, entity_id, action, user_id, actor_type, note)
  values ('invoice_email', v_ob.email_id, 'reply_sent', v_ob.queued_by, 'human', v_ob.body_text);

  return jsonb_build_object('success', true);
end;
$$;

-- 送信失敗を記録
create or replace function invoice_outbox_mark_failed(p_secret text, p_outbox_id uuid, p_error text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not invoice_intake_secret_ok(p_secret) then raise exception '認証エラー'; end if;
  update invoice_email_outbox set status = 'failed', error = p_error where id = p_outbox_id;
  return jsonb_build_object('success', true);
end;
$$;

-- ============================================================
-- portal_permissions: 請求書管理のタイル権限を追加（既存テーブルへのinsertのみ）
-- ============================================================
insert into portal_permissions (role, system_key, allowed)
select v.r, 'invoices', v.a from (values
  ('CEO', true), ('HQ', true), ('TEAM', false), ('TENCHO', false), ('SHAIN', false), ('AL', false)
) as v(r, a)
on conflict (role, system_key) do nothing;

-- ============================================================
-- Storage: 非公開バケット invoice-files（20MB上限・署名URL閲覧のみ）
-- report-photos（公開バケット）は使用しない（監査R5の教訓＝請求書は機密）
-- パス規約: {email_id}/{添付連番}_{ファイル名}
-- ============================================================
-- 2026-08-24: 実機で「zip添付・Outlook経由のPDF等がallowed_mime_typesに一致せず
-- アップロードが静かに失敗する」事故が発生（エラーがログにしか出ずUI上は成功に見えた）。
-- メール添付はMIMEタイプが多様（zip/octet-stream等）で許可リスト方式に向かないため、
-- 種類は制限せずサイズ上限(20MB)とアクセス制御(RLS・非公開・署名URL)だけで守る方針に変更
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('invoice-files', 'invoice-files', false, 20971520, null)
on conflict (id) do update set allowed_mime_types = null;

drop policy if exists invoice_files_read on storage.objects;
create policy invoice_files_read on storage.objects for select
  using (bucket_id = 'invoice-files' and invoice_can_access());
-- 2026-08-24追加: 手動添付アップロード用。処理権限者は自分のJWTで直接storageへアップロードできる
-- （メタデータ登録はinvoice_attach_manual_file RPC経由・監査ログに記録される）
drop policy if exists invoice_files_insert on storage.objects;
create policy invoice_files_insert on storage.objects for insert
  with check (bucket_id = 'invoice-files' and invoice_can_access());
-- update/deleteの直接policyは無し＝Edge Function(service_role)のみ

-- 確認用（本番適用後、SQL Editorで実行して構造・初期値を確認）:
-- select role, system_key, allowed from portal_permissions where system_key = 'invoices';
-- select key, length(value) from app_secrets where key = 'invoice_intake_secret';
-- select id, public, file_size_limit from storage.buckets where id = 'invoice-files';
