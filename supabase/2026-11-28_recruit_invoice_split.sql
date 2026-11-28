-- 2026-11-28 求人広告の請求書を、内訳シートの店舗ごとの明細に分ける（担当D・社長依頼）
--   呼び元: EF recruit-invoice-split。MF には何も登録しない（下書きを作るのは既存の invoice-journal-draft、承認は人）。
--   対象の取引先・エリアと店舗の対応・開始月は app_settings.recruit_invoice_split（このリポジトリには書かない）。
--   戻し方: 2026-11-28_recruit_invoice_split_rollback.sql
begin;

create or replace function public.recruit_invoice_apply_split(p_invoice uuid, p_month date, p_lines jsonb) returns text
language plpgsql security definer set search_path = public as $function$
declare v invoices%rowtype; v_sub numeric; v_tax numeric; v_label text;
begin
  select * into v from invoices where id = p_invoice for update;
  if not found then return 'not_found'; end if;
  if v.mf_journal_id is not null or v.invoice_status = 'cancelled'
     or coalesce(v.current_stage, '') in ('approved', 'payment_waiting', 'paid', 'completed') then return 'locked'; end if;
  if coalesce(v.journal_draft ->> 'edited_by_human', 'false') = 'true'
     or exists (select 1 from invoice_lines where invoice_id = p_invoice and resolved_by = 'human') then return 'edited_by_human'; end if;
  if coalesce(v.lines_check -> 'recruit_split' ->> 'status', '') = 'split' then return 'already'; end if;
  select sum((x ->> 'amount')::numeric), sum((x ->> 'tax_amount')::numeric) into v_sub, v_tax from jsonb_array_elements(p_lines) x;
  if v_sub is null or v_sub + v_tax <> v.amount then raise exception '明細の税込合計が請求額と合いません'; end if;
  v_label := '求人広告費 ' || to_char(p_month, 'YYYY"年"FMMM"月分"');

  delete from invoice_lines where invoice_id = p_invoice;
  insert into invoice_lines (invoice_id, line_no, description, item, store_text, amount, tax_rate, tax_amount, resolved_store_id, resolved_by, source, resolve_info)
  select p_invoice, o.n, v_label, v_label, s.name, (o.x ->> 'amount')::numeric, 10, (o.x ->> 'tax_amount')::numeric, s.id, 'rule', 'recruit_split',
         jsonb_build_object('via', 'recruit_split', 'confidence', 'sheet')
    from jsonb_array_elements(p_lines) with ordinality as o(x, n)
    join stores s on s.id = (o.x ->> 'store_id')::uuid;
  if (select count(*) from invoice_lines where invoice_id = p_invoice) <> jsonb_array_length(p_lines) then raise exception '店舗が見つからない行があります'; end if;

  update invoices set
     target_year_month = coalesce(target_year_month, p_month),
     subtotal_amount = v_sub, tax_amount = v_tax,
     lines_extracted_at = coalesce(lines_extracted_at, now()),
     lines_check = coalesce(lines_check, '{}'::jsonb) || jsonb_build_object(
       'line_amounts_include_tax', false,
       'recruit_split', jsonb_build_object('status', 'split', 'month', to_char(p_month, 'YYYY-MM'), 'at', now())),
     blocked_reason = null, updated_at = now()
   where id = p_invoice;
  delete from invoice_stores where invoice_id = p_invoice;
  insert into invoice_stores (invoice_id, store_id) select distinct p_invoice, resolved_store_id from invoice_lines where invoice_id = p_invoice;
  insert into invoice_audit_logs (entity_type, entity_id, action, actor_type, note, new_value)
  values ('invoice', p_invoice, 'recruit_invoice_split', 'ai', v_label || 'を内訳シートの店舗ごとに分けました（税抜）', jsonb_build_object('lines', p_lines));
  return 'split';
end $function$;

create or replace function public.recruit_invoice_mark_mismatch(p_invoice uuid, p_month date, p_note text) returns void
language plpgsql security definer set search_path = public as $function$
begin
  update invoices set
     lines_check = coalesce(lines_check, '{}'::jsonb) || jsonb_build_object(
       'recruit_split', jsonb_build_object('status', 'mismatch', 'month', to_char(p_month, 'YYYY-MM'), 'note', p_note, 'at', now())),
     current_stage = 'journal_draft', blocked_reason = '求人広告の店舗分け: ' || p_note, updated_at = now()
   where id = p_invoice and mf_journal_id is null and coalesce(current_stage, '') not in ('approved', 'payment_waiting', 'paid', 'completed');
  if found then
    insert into invoice_audit_logs (entity_type, entity_id, action, actor_type, note)
    values ('invoice', p_invoice, 'recruit_invoice_split_mismatch', 'ai', p_note);
  end if;
end $function$;

revoke all on function public.recruit_invoice_apply_split(uuid, date, jsonb) from public, anon, authenticated;
revoke all on function public.recruit_invoice_mark_mismatch(uuid, date, text) from public, anon, authenticated;
grant execute on function public.recruit_invoice_apply_split(uuid, date, jsonb) to service_role;
grant execute on function public.recruit_invoice_mark_mismatch(uuid, date, text) to service_role;

create or replace function public.recruit_invoice_split_trigger() returns void
language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $function$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/recruit-invoice-split';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_secret text;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'recruit_invoice_split_trigger: app_secrets.notify_slack_secret が未設定'; return; end if;
  perform net.http_post(url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('trigger', 'pg_cron'), timeout_milliseconds := 120000);
end $function$;
revoke all on function public.recruit_invoice_split_trigger() from public, anon, authenticated;
select cron.schedule('recruit-invoice-split', '5,35 22-23,0-14 * * *', 'select public.recruit_invoice_split_trigger()');
commit;
