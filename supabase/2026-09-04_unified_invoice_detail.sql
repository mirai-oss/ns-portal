-- 共通請求書詳細への完全統合（2026-09-04・統合改修指示書【確定版】追加指示）
-- 「メール経由」「アップロード経由」で分かれていた請求書処理画面を、invoice_idをキーとした
-- 1つの共通画面へ統合する。統合にあたり、これまでinvoice_emails（email_id）にしか
-- 紐付けられなかった「コメント」「手動証憑追加」を、invoices（invoice_id）にも紐付けられる
-- よう拡張する（=機能を落とさずに統合する。指示書§2）。
--
-- 方針：既存のRPC・カラムは残したまま、invoice_idの受け皿を追加する後方互換の拡張とする
-- （invoice_email_id方式で動いている既存の呼び出しコードを壊さない）

-- ---- invoice_comments: invoice_idでも紐付けられるようにする ----
alter table invoice_comments alter column email_id drop not null;
alter table invoice_comments add column if not exists invoice_id uuid references invoices(id);
alter table invoice_comments drop constraint if exists invoice_comments_email_or_invoice_chk;
alter table invoice_comments add constraint invoice_comments_email_or_invoice_chk
  check (email_id is not null or invoice_id is not null);
create index if not exists invoice_comments_invoice_idx on invoice_comments (invoice_id, created_at asc);

create or replace function invoice_add_comment(p_email_id uuid, p_body text, p_invoice_id uuid default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_comment_id uuid;
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  if p_body is null or length(trim(p_body)) = 0 then raise exception 'コメントを入力してください'; end if;
  if p_email_id is null and p_invoice_id is null then raise exception '対象が指定されていません'; end if;
  if p_email_id is not null and not exists(select 1 from invoice_emails where id = p_email_id) then raise exception '対象が見つかりません'; end if;
  if p_invoice_id is not null and not exists(select 1 from invoices where id = p_invoice_id) then raise exception '対象が見つかりません'; end if;

  insert into invoice_comments(email_id, invoice_id, user_id, body) values (p_email_id, p_invoice_id, auth.uid(), trim(p_body))
  returning id into v_comment_id;

  insert into invoice_audit_logs(entity_type, entity_id, action, user_id, note)
  values (
    case when p_email_id is not null then 'invoice_email' else 'invoice' end,
    coalesce(p_email_id, p_invoice_id),
    'comment_added', auth.uid(), left(trim(p_body), 500)
  );

  return v_comment_id;
end;
$$;

-- ---- invoice_attach_manual_file: invoice_idでも紐付けられるようにする ----
-- invoice_attachments.invoice_idは2026-09-04_invoice_attachments_standalone.sqlで追加済み
create or replace function invoice_attach_manual_file(
  p_email_id uuid, p_file_name text, p_mime_type text, p_storage_path text, p_file_hash text, p_size_bytes bigint,
  p_invoice_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_attachment_id uuid; v_dup boolean;
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  if p_email_id is null and p_invoice_id is null then raise exception '対象が指定されていません'; end if;
  if p_email_id is not null and not exists(select 1 from invoice_emails where id = p_email_id) then raise exception '対象が見つかりません'; end if;
  if p_invoice_id is not null and not exists(select 1 from invoices where id = p_invoice_id) then raise exception '対象が見つかりません'; end if;

  insert into invoice_attachments(email_id, invoice_id, file_name, mime_type, storage_path, file_hash, size_bytes)
  values (p_email_id, p_invoice_id, p_file_name, p_mime_type, p_storage_path, p_file_hash, p_size_bytes)
  returning id into v_attachment_id;

  select exists(select 1 from invoice_attachments where file_hash = p_file_hash and id <> v_attachment_id) into v_dup;
  if v_dup then
    if p_email_id is not null then
      update invoice_emails set duplicate_suspected = true where id = p_email_id;
    else
      update invoices set duplicate_suspected = true where id = p_invoice_id;
    end if;
  end if;

  insert into invoice_audit_logs(entity_type, entity_id, action, user_id, note)
  values (
    case when p_email_id is not null then 'invoice_email' else 'invoice' end,
    coalesce(p_email_id, p_invoice_id),
    'manual_attach', auth.uid(), p_file_name
  );

  return v_attachment_id;
end;
$$;
