-- 2026-11-28_recruit_invoice_split.sql の戻し（分けた明細・仕訳の下書きは変えない）
begin;
select cron.unschedule('recruit-invoice-split');
drop function if exists public.recruit_invoice_split_trigger();
drop function if exists public.recruit_invoice_apply_split(uuid, date, jsonb);
drop function if exists public.recruit_invoice_mark_mismatch(uuid, date, text);
delete from app_settings where key = 'recruit_invoice_split';
commit;
