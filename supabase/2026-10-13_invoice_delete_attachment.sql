-- 担当C: 請求書の添付ファイルの削除（同じ請求書が2つ添付されたときの片方削除用）
--
-- 【事前報告様式（DB変更）】
-- 理由: 取引先によっては同じ請求書PDFが名前違いで2つ添付されて届く（例: 食べログ INV02962546.pdf と 1 (1).pdf）。
--       余分な方を請求書の詳細画面から削除できるようにする。現状は invoice_attachments に削除の手段（RLSの削除ポリシー・RPC）が無い。
-- 現構造: invoice_attachments は select のポリシーだけ（画面から削除できない）。
-- 変更: 関数 invoice_delete_attachment(p_attachment_id, p_reason) を1つ追加するだけ。表・列・ポリシーは変更しない。
--   ・権限＝請求書権限(invoice_can_access)。履歴を invoice_audit_logs に残す（ファイル名・ハッシュ・理由）
--   ・安全のため削除できない場合: ①そのメール／請求書のMF仕訳が登録済み（証憑として使われたため）②その請求書の最後の1つ（証憑がゼロになる）
--   ・削除する添付が請求書の attachment_id / source_attachment_id になっている場合は、同じファイル（ハッシュ）の別の添付へ付け替える
--   ・ストレージ上のファイル自体は残す（取り消しに備える。表の行だけを削除）
-- 既存データへの影響: なし。 migration: 何度流しても壊れない。 rollback: drop function invoice_delete_attachment(uuid,text);
create or replace function public.invoice_delete_attachment(p_attachment_id uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a public.invoice_attachments;
  v_remaining int;
  v_alt uuid;
  v_audit_entity uuid;
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  select * into a from public.invoice_attachments where id = p_attachment_id;
  if not found then raise exception '添付が見つかりません'; end if;

  -- MF仕訳が登録済み（この添付が証憑として使われた）請求書には触れない
  if exists (select 1 from public.invoices i where i.mf_journal_id is not null
       and (i.email_id = a.email_id and a.email_id is not null or i.id = a.invoice_id and a.invoice_id is not null)) then
    raise exception 'この請求書はマネーフォワードへ仕訳登録済みのため、添付は削除できません（証憑として使われています）';
  end if;

  -- 証憑がゼロにならないようにする（同じメール／同じ請求書の他の添付が残ること）
  select count(*) into v_remaining from public.invoice_attachments x
    where x.id <> a.id and ((a.email_id is not null and x.email_id = a.email_id) or (a.invoice_id is not null and x.invoice_id = a.invoice_id));
  if v_remaining = 0 then raise exception 'この請求書の最後の添付のため削除できません'; end if;

  -- 同じファイル（ハッシュ）の別の添付、無ければ同じメールの別の添付へ付け替える
  select x.id into v_alt from public.invoice_attachments x
    where x.id <> a.id and ((a.email_id is not null and x.email_id = a.email_id) or (a.invoice_id is not null and x.invoice_id = a.invoice_id))
    order by (x.file_hash is not distinct from a.file_hash) desc, x.created_at limit 1;
  update public.invoices set attachment_id = v_alt, updated_at = now() where attachment_id = a.id;
  update public.invoices set source_attachment_id = v_alt where source_attachment_id = a.id;

  v_audit_entity := coalesce(a.email_id, a.invoice_id);
  delete from public.invoice_attachments where id = a.id;
  insert into public.invoice_audit_logs(entity_type, entity_id, action, user_id, note, old_value)
    values ('invoice_email', v_audit_entity, 'attachment_deleted', auth.uid(),
      '添付を削除: ' || coalesce(a.file_name,'') || coalesce('（理由: ' || nullif(btrim(p_reason),'') || '）',''),
      jsonb_build_object('file_name', a.file_name, 'file_hash', a.file_hash, 'storage_path', a.storage_path));
  return jsonb_build_object('success', true, 'remaining', v_remaining);
end $$;
