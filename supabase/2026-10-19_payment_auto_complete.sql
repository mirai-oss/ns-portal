-- 2026-10-19 担当C: 請求書フローの簡素化 第1段階
-- ①「振込済み」にした時点で自動的に完了（支払確認済み）にする。取り消し（paid以外へ戻す）で完了も外れる
-- ②すでに「振込済み」なのに支払確認待ちで止まっているものを完了にする
-- ③MF登録済み・支払方法が設定済みなのに「振込待ち」に入っていないものを振込待ちにする（給与・売上入金・売上入金メールは除く）
create or replace function public.invoice_paid_autocomplete() returns trigger language plpgsql as $$
begin
  if new.payment_status = 'paid' then
    if new.payment_verified_at is null then
      new.payment_verified_at := coalesce(new.paid_at, now());
      new.payment_verified_by := coalesce(new.paid_by, new.payment_verified_by);
    end if;
  elsif old.payment_status = 'paid' then
    new.payment_verified_at := null;
    new.payment_verified_by := null;
  end if;
  return new;
end $$;

drop trigger if exists trg_invoice_paid_autocomplete on public.invoices;
create trigger trg_invoice_paid_autocomplete before update of payment_status on public.invoices
  for each row execute function public.invoice_paid_autocomplete();

-- ②
update public.invoices set payment_status = 'paid'
 where payment_status = 'paid' and payment_verified_at is null and mf_journal_id is not null;

-- ③
update public.invoices i set payment_status = 'wait', updated_at = now()
 where i.payment_status = 'not_ready' and i.mf_journal_id is not null and i.invoice_status <> 'cancelled'
   and coalesce(i.is_payroll_related,false) = false and coalesce(i.is_receivable_related,false) = false
   and coalesce(i.duplicate_suspected,false) = false and coalesce(i.bank_account_change_detected,false) = false
   and coalesce(i.journal_draft->>'kind','') <> 'sales_deposit'
   and exists (select 1 from public.vendor_bank_accounts b where b.vendor_id = i.vendor_id and b.is_current and b.payment_method is not null
               and (b.store_id is null or b.store_id = i.store_id));
