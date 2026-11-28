-- 担当C 2026-11-28（社長要望）: 実際に支払った（入金された）金額が請求額と違うときは、理由が無いと「振込済み・入金済み」にできない
-- 追加列: paid_amount（実際の金額。未入力は null）／paid_diff_reason（差がある理由）。振込済みを取り消すと両方とも空に戻る。
-- 戻し: drop trigger trg_invoice_paid_diff on public.invoices; drop function public.invoice_paid_diff_check(); alter table public.invoices drop column paid_amount, drop column paid_diff_reason;
begin;
alter table public.invoices add column if not exists paid_amount numeric, add column if not exists paid_diff_reason text;
create or replace function public.invoice_paid_diff_check() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.payment_status is distinct from 'paid' then
    new.paid_amount := null; new.paid_diff_reason := null;
  elsif new.paid_amount is not null and new.paid_amount is distinct from new.amount and length(btrim(coalesce(new.paid_diff_reason,''))) = 0 then
    raise exception '実際の金額（%）が請求額（%）と違います。理由を入力してください', new.paid_amount, new.amount;
  end if;
  return new;
end $$;
drop trigger if exists trg_invoice_paid_diff on public.invoices;
create trigger trg_invoice_paid_diff before update of payment_status, paid_amount, paid_diff_reason on public.invoices
  for each row execute function public.invoice_paid_diff_check();
commit;
