-- 2026-10-21 担当C: 請求書メールを「請求書が1件も作られていない」まま完了にできないようにする（メールが受信トレイから消え、請求書も無い状態を防ぐ）
-- 経緯: 2026-10-19(SSS)・2026-10-21(合同会社310)に、AI読み取り→処理開始→完了を数秒で進めたところ、請求書の記録が作られないままメールだけ完了になり、
--       請求書メールの一覧にも請求書の一覧にも出なくなった。完了の処理が請求書の有無を確認していなかった。
-- 対象: メール種別=請求書、または自動分類が 請求書(添付あり)/請求書(送付のお知らせ) で、請求書が0件のメール。請求書ではないメールは「対象外にする」を使う。

create or replace function public.invoice_complete(p_email_id uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_email invoice_emails;
begin
  select * into v_email from invoice_emails where id = p_email_id;
  if v_email is null then raise exception '対象が見つかりません'; end if;
  if v_email.processing_user_id is distinct from auth.uid() then
    raise exception '処理中の担当者本人のみ完了できます';
  end if;
  if (v_email.mail_kind = 'invoice' or v_email.auto_category in ('invoice_attachment','invoice_notice'))
     and not exists(select 1 from invoices where email_id = p_email_id) then
    raise exception '請求書がまだ作成されていません。完了するとこのメールは受信トレイから消えます。先に「請求書を自動作成」を押すか、請求書ではないメールなら「対象外にする」を使ってください';
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

CREATE OR REPLACE FUNCTION public.invoice_bulk_action(p_email_ids uuid[], p_action text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid; v_email invoice_emails; v_success int := 0; v_skipped jsonb := '[]'::jsonb; v_holder text;
begin
  if not invoice_can_access() then raise exception '権限がありません'; end if;
  if p_action not in ('start','complete','waiting_payment','not_applicable','mark_important') then raise exception '不正なアクションです'; end if;

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
      if (v_email.mail_kind = 'invoice' or v_email.auto_category in ('invoice_attachment','invoice_notice')) and not exists(select 1 from invoices where email_id = v_id) then
        v_skipped := v_skipped || jsonb_build_object('id', v_id, 'reason', '請求書がまだ作成されていないため完了にしていません');
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

    elsif p_action = 'not_applicable' then
      if v_email.mail_status = 'archived' then
        v_skipped := v_skipped || jsonb_build_object('id', v_id, 'reason', '既に対象外');
        continue;
      end if;
      update invoice_emails set
        mail_status = 'archived',
        processing_user_id = null, processing_started_at = null, locked_at = null, lock_expires_at = null,
        updated_at = now()
      where id = v_id;
      insert into invoice_audit_logs(entity_type, entity_id, action, user_id, note)
      values ('invoice_email', v_id, 'mark_not_applicable', auth.uid(), coalesce(p_note, '一括処理'));
      v_success := v_success + 1;

    elsif p_action = 'mark_important' then
      update invoice_emails set is_important = true, updated_at = now() where id = v_id;
      insert into invoice_audit_logs(entity_type, entity_id, action, user_id, note)
      values ('invoice_email', v_id, 'mark_important', auth.uid(), coalesce(p_note, '一括処理'));
      v_success := v_success + 1;
    end if;
  end loop;

  return jsonb_build_object('success_count', v_success, 'skipped', v_skipped);
end;
$function$;
