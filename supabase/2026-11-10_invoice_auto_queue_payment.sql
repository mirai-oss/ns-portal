-- 2026-11-10 担当C: MF登録済みの請求書は、支払方法が設定済みなら自動で「振込待ち」(payment_status='wait')に入れる（サーバー側）。
-- 経緯: 画面の承認(apvRun_)では v151 から自動で振込待ちに入るが、インフォマート取込・メール取込などの別経路でMF登録された請求書は
--       payment_status が not_ready のまま止まり、振込待ち／要対応のどこにも出なかった（例: 2026-11 のインフォマート 25件・RSS）。
-- 条件（画面の autoQueuePayment_ と同じ）: MF登録済み・現在の支払方法が設定済み（店舗の口座→店舗なしの口座→1件だけの口座）・重複疑い/口座変更未承認でない・
--       給与/売上入金/売上入金メールではない・取消でない。

create or replace function public.invoice_payment_method_ok(p_vendor_id uuid, p_store_id uuid) returns boolean
language sql stable as $$
  select exists (
    select 1 from public.vendor_bank_accounts b
     where b.vendor_id = p_vendor_id and b.is_current and b.payment_method is not null
       and (b.store_id is null or b.store_id = p_store_id)
  )
$$;

create or replace function public.invoice_auto_queue_payment() returns trigger language plpgsql as $$
begin
  if new.mf_journal_id is not null and (tg_op = 'INSERT' or old.mf_journal_id is null)
     and new.payment_status = 'not_ready' and new.invoice_status is distinct from 'cancelled'
     and coalesce(new.is_payroll_related, false) = false and coalesce(new.is_receivable_related, false) = false
     and coalesce(new.duplicate_suspected, false) = false and coalesce(new.bank_account_change_detected, false) = false
     and coalesce(new.journal_draft->>'kind', '') <> 'sales_deposit'
     and new.vendor_id is not null and public.invoice_payment_method_ok(new.vendor_id, new.store_id) then
    new.payment_status := 'wait';
  end if;
  return new;
end $$;

drop trigger if exists trg_invoice_auto_queue_payment on public.invoices;
create trigger trg_invoice_auto_queue_payment before insert or update of mf_journal_id on public.invoices
  for each row execute function public.invoice_auto_queue_payment();

-- 既にMF登録済みで not_ready のまま止まっているもの（条件は上と同じ）を振込待ちにする
update public.invoices i set payment_status = 'wait', updated_at = now()
 where i.payment_status = 'not_ready' and i.mf_journal_id is not null and i.invoice_status is distinct from 'cancelled'
   and coalesce(i.is_payroll_related, false) = false and coalesce(i.is_receivable_related, false) = false
   and coalesce(i.duplicate_suspected, false) = false and coalesce(i.bank_account_change_detected, false) = false
   and coalesce(i.journal_draft->>'kind', '') <> 'sales_deposit'
   and i.vendor_id is not null and public.invoice_payment_method_ok(i.vendor_id, i.store_id);

-- 戻し方: drop trigger trg_invoice_auto_queue_payment on public.invoices;（個別に戻すときは update public.invoices set payment_status='not_ready' where id = ...）
