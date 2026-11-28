-- 段階2（2026-11-28_bank_ledger_stage2.sql）の取り消し。状態: 下書き（未適用）
-- 関数を消すだけ。表・データ・原本ファイル・段階1の物には触らない（取込を止めるだけで足りるときは、これも不要）。
drop function if exists public.bank_import_fail(uuid, text);
drop function if exists public.bank_import_commit(uuid);
drop function if exists public.bank_import_ingest(uuid, jsonb, boolean);
drop function if exists public.bank_import_record_verification(uuid, text, integer);
drop function if exists public.bank_import_attach_original(uuid, text, integer, text);
drop function if exists public.bank_import_register(uuid, text, text, date, date);
drop function if exists public.bank_account_upsert(text, text, text, text, uuid);
drop function if exists public.bank_assert_service();
