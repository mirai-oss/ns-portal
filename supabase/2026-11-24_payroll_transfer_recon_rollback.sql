-- =============================================================
-- 2026-11-24_payroll_transfer_recon.sql の戻し（下書き）
--   足した関数を外す。足した表は、**8 つとも行が 1 件も無いときだけ**消す（1 件でも記録があれば、表・守りの引き金・スイッチの行はすべて残す＝記録を消さない）。
--   既存の表・関数・行（給与データ・口座・月ごとの支払方法・支払記録）には、もともと触れていないので、戻すものは無い。
--   表を残した場合: 関数が無くなるので、画面・取り込みからは読み書きできなくなる（記録は残る）。もう一度使うときは、元の SQL を流し直す。
-- =============================================================

-- 画面・取り込みの入口
drop function if exists public.payroll_transfer_recon_slack_summary(uuid);
drop function if exists public.payroll_transfer_recon_status(text, uuid);
drop function if exists public.payroll_transfer_evidence_unavailable(text, uuid, text, text, text, text, uuid, uuid, text);
drop function if exists public.payroll_transfer_evidence_add(text, uuid, text, text, text, text, bigint, text, timestamptz, text, text, uuid, uuid, text);
drop function if exists public.payroll_transfer_manual_revoke(uuid, uuid, text);
drop function if exists public.payroll_transfer_manual_confirm(uuid, uuid, text, text, uuid);
drop function if exists public.payroll_transfer_batch_complete(uuid, text);
drop function if exists public.bank_bulk_transfer_ingest(jsonb, jsonb);
drop function if exists public.payroll_transfer_recon_run(uuid);
drop function if exists public.payroll_transfer_mf_total_record(uuid, text, text, integer, date, text, numeric, text, boolean);
drop function if exists public.payroll_transfer_batch_discard(uuid, text);
drop function if exists public.payroll_transfer_batch_freeze(text, uuid, date, boolean, boolean);
-- 内部用
drop function if exists public.payroll_recon_eval(uuid, text);
drop function if exists public.payroll_recon_complete(uuid, text, text, text);
drop function if exists public.payroll_recon_set_line(uuid, text, text, text);
drop function if exists public.payroll_recon_set_batch(uuid, text, text, text, jsonb);
drop function if exists public.payroll_recon_log(uuid, uuid, text, text, text, text, text, jsonb);
drop function if exists public.payroll_transfer_status_label(text, text);
drop function if exists public.payroll_recon_acct_key(text, text, text, text);
drop function if exists public.payroll_recon_kana_norm(text);
drop function if exists public.payroll_recon_flag(text);
drop function if exists public.payroll_recon_setting();
drop function if exists public.payroll_recon_can();
drop function if exists public.payroll_recon_is_service();

do $$
declare v_rows bigint := 0; v_tbl text; v_n bigint;
  c_tables constant text[] := array['payroll_transfer_recon_events', 'payroll_transfer_evidence', 'payroll_transfer_manual_confirmations', 'payroll_mf_total_matches',
                                    'payroll_transfer_batch_lines', 'bank_bulk_transfer_details', 'bank_bulk_transfers', 'payroll_transfer_batches'];
begin
  foreach v_tbl in array c_tables loop
    if to_regclass('public.' || v_tbl) is not null then
      execute format('select count(*) from public.%I', v_tbl) into v_n;
      v_rows := v_rows + v_n;
    end if;
  end loop;
  if v_rows > 0 then
    raise notice '振込照合の表に記録が % 件あるため、表・守りの引き金・スイッチの行は残しました（関数だけ外しました）', v_rows;
    return;
  end if;
  -- 記録が 1 件も無い: 表（参照される側をあとに）・守りの引き金の関数・スイッチの行を消す
  foreach v_tbl in array c_tables loop
    execute format('drop table if exists public.%I', v_tbl);
  end loop;
  drop function if exists public.payroll_recon_append_only();
  drop function if exists public.payroll_recon_guard();
  delete from public.app_settings where key = 'payroll_transfer_recon';
end $$;
