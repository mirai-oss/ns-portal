-- 段階1（2026-11-27_bank_ledger_stage1.sql）の取り消し。状態: 下書き（未適用）
-- 使いどころ: 段階1だけを適用し、まだ明細・取得履歴・原本ファイルが 1 件も入っていない間（＝新しい箱が空のまま）。
-- 安全装置（何かを消す前に、すべて確かめる。1 つでも当てはまれば、何も消さずに止まる）:
--   ・新しい 7 つの表のどれかに 1 行でもデータがある（明細・取得履歴・原本の台帳・訂正履歴・取得状態・口座・入金備考）
--   ・バケット bank-csv-originals に、原本ファイルが 1 つでもある
-- データが入ったあとの取り消しは、消さずに「取込を止める」だけで足りる（箱は足すだけの作りなので、残しても既存の動きに影響しない）。
-- 既存のテーブル・関数・バケットには、触らない。新しいバケットは空のまま残す（理由は末尾）。

do $$
declare
  n bigint := 0; t text; c bigint; v_objs bigint := 0;
begin
  foreach t in array array['bank_transactions', 'bank_import_files', 'bank_csv_originals', 'bank_transaction_events',
                           'bank_account_sync_state', 'bank_accounts', 'bank_deposit_notes'] loop
    if to_regclass('public.' || t) is not null then
      execute format('select count(*) from public.%I', t) into c;
      n := n + c;
    end if;
  end loop;
  if to_regclass('storage.objects') is not null then
    select count(*) into v_objs from storage.objects where bucket_id = 'bank-csv-originals';
  end if;
  if n > 0 then
    raise exception '新しい銀行の表にすでに % 件のデータが入っています。取り消しを中止しました（データを守るため）。取込を止めてから、別途相談してください', n;
  end if;
  if v_objs > 0 then
    raise exception '原本の置き場 bank-csv-originals に % 個のファイルがあります。取り消しを中止しました（原本は消しません）', v_objs;
  end if;
end $$;

drop policy if exists bank_csv_originals_read on storage.objects;
drop policy if exists bank_csv_originals_insert on storage.objects;

drop function if exists public.bank_deposit_daily(date, date);
drop function if exists public.bank_sync_status();
drop function if exists public.bank_tx_correct(uuid, jsonb, text);

drop trigger if exists bank_tx_guard_trg on public.bank_transactions;
drop trigger if exists bank_tx_events_append_only on public.bank_transaction_events;
drop trigger if exists bank_csv_originals_append_only on public.bank_csv_originals;
drop trigger if exists bank_import_files_guard_trg on public.bank_import_files;

drop table if exists public.bank_deposit_notes;
drop table if exists public.bank_account_sync_state;
drop table if exists public.bank_transaction_events;
drop table if exists public.bank_transactions;
drop table if exists public.bank_import_files;
drop table if exists public.bank_csv_originals;
drop table if exists public.bank_accounts;

drop function if exists public.bank_tx_guard();
drop function if exists public.bank_append_only();
drop function if exists public.bank_import_files_guard();
drop function if exists public.bank_store_visible(uuid);
drop function if exists public.bank_ledger_admin();

-- バケット bank-csv-originals は、この SQL では消さない（残す）。
--   Supabase は storage.buckets への直接の delete を禁止している（「Use the Storage API instead」。実環境の事前検証で確認）。
--   空のバケットが残っても、何にも影響しない（非公開・ポリシーも上で外してあるので、誰も読み書きできない）。
--   バケットも消したいときは、空であることを確かめてから、ダッシュボードの Storage 画面か Storage API（DELETE /storage/v1/bucket/bank-csv-originals）で消す。
