-- 段階1（2026-11-27_bank_ledger_stage1.sql）の取り消し。状態: 下書き（未適用）
-- 使いどころ: 段階1だけを適用し、まだ明細・取得履歴が 1 件も入っていない間（＝新しい箱が空のまま）。
-- 安全装置: 1 件でもデータが入っていたら、何も消さずに止まる（段階2以降の取り消しは、取込を止めるだけで足りる＝箱は足すだけの作りなので、消す必要が無い）。
-- 既存のテーブル・関数・バケットには、触らない。

do $$
declare n bigint := 0;
begin
  if to_regclass('public.bank_transactions') is not null then
    select n + count(*) into n from public.bank_transactions;
  end if;
  if to_regclass('public.bank_import_files') is not null then
    select n + count(*) into n from public.bank_import_files;
  end if;
  if to_regclass('public.bank_transaction_events') is not null then
    select n + count(*) into n from public.bank_transaction_events;
  end if;
  if to_regclass('public.bank_accounts') is not null then
    select n + count(*) into n from public.bank_accounts;
  end if;
  if to_regclass('public.bank_deposit_notes') is not null then
    select n + count(*) into n from public.bank_deposit_notes;
  end if;
  if n > 0 then
    raise exception '新しい銀行の表にすでに % 件のデータが入っています。取り消しを中止しました（データを守るため）。取込を止めてから、別途相談してください', n;
  end if;
  -- 原本の置き場にファイルが入っていたら、バケットは消さない（下で判定）
end $$;

drop policy if exists bank_csv_originals_read on storage.objects;
drop policy if exists bank_csv_originals_insert on storage.objects;

drop function if exists public.bank_deposit_daily(date, date);
drop function if exists public.bank_sync_status();
drop function if exists public.bank_tx_correct(uuid, jsonb, text);

drop trigger if exists bank_tx_guard_trg on public.bank_transactions;
drop trigger if exists bank_tx_events_append_only on public.bank_transaction_events;
drop trigger if exists bank_import_files_guard_trg on public.bank_import_files;

drop table if exists public.bank_deposit_notes;
drop table if exists public.bank_account_sync_state;
drop table if exists public.bank_transaction_events;
drop table if exists public.bank_transactions;
drop table if exists public.bank_import_files;
drop table if exists public.bank_accounts;

drop function if exists public.bank_tx_guard();
drop function if exists public.bank_append_only();
drop function if exists public.bank_import_files_guard();
drop function if exists public.bank_store_visible(uuid);
drop function if exists public.bank_ledger_admin();

-- 空のときだけバケットを消す（中にファイルがあれば残す）
delete from storage.buckets b
 where b.id = 'bank-csv-originals'
   and not exists (select 1 from storage.objects o where o.bucket_id = 'bank-csv-originals');
