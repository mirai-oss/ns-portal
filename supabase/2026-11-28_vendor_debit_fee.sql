-- 担当C 2026-11-28（社長要望）: 引き落とし手数料が上乗せされる取引先は、仕訳下書きに手数料の行を足す
-- 追加列: vendor_invoice_policies.debit_fee_amount（税込・円）/ debit_fee_account。西田コーポレーション（N-Style）= 880円・支払手数料・課税仕入10%
-- 戻し: update public.vendor_invoice_policies set debit_fee_amount=null where vendor_id='9ebc62ad-d6c2-4059-b57a-75605113859d';
begin;
alter table public.vendor_invoice_policies add column if not exists debit_fee_amount numeric, add column if not exists debit_fee_account text, add column if not exists fee_credit_account text, add column if not exists fee_credit_sub text;
insert into public.vendor_invoice_policies (vendor_key, tenant_id, vendor_id, debit_fee_amount, debit_fee_account, fee_credit_account, fee_credit_sub, note)
values ('株式会社西田コーポレーション','nstyle','9ebc62ad-d6c2-4059-b57a-75605113859d',880,'支払手数料','買掛金','西田コーポレーション','引き落とし時に振替手数料880円が上乗せされる')
on conflict (vendor_key, tenant_id) do update set vendor_id=excluded.vendor_id, debit_fee_amount=excluded.debit_fee_amount, debit_fee_account=excluded.debit_fee_account, fee_credit_account=excluded.fee_credit_account, fee_credit_sub=excluded.fee_credit_sub, updated_at=now();
commit;
