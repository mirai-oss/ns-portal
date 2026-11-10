-- 2026-11-10 担当B 【未適用・司令塔の「本人確認済み」連絡後にユーザー実行】2026-10 の誤サイン（9月分を10月分として誤ってサイン）の取消 + 2026-10 を確定前に戻す（b案）
-- 【対象】sf_cash_handoff_signatures の year_month='2026-10'・契約 sez093z1（トーホー）の全件（想定8件=渡した側8・受取側8・完了5）。氏名はファイルに持たない（年月×契約の全件）
-- 【内容】①取消履歴(sf_cash_handoff_cancellations)に8件を記録（理由固定・戻す前の状態・元の画像パスを保存） ②サイン・確認・完了をリセット（再サイン可能に）
--        ③payroll_finalized の 2026-10 トーホー行（backfill行）を削除＝現金手渡し画面から10月が消え、給料確定ボタンを押すまで出ない
-- 【サイン画像】消さない。履歴の archived_paths に元のパス(orig_*)を保存し、storage上の実体はそのまま残す（SQLからはstorageのコピーができないため。画面からの取消ではarchive名へコピーする）
-- 【paid_at（振込完了印）】読み取りで確認: この8人の2026-10の給与仕訳は存在せず（2026-09のみ・paid済み・MF登録済み）、2026-10の印は付いていない＝戻す対象なし。2026-09の仕訳には一切触らない
-- 【9月分】この8人の2026-09のサイン記録は8人とも存在し完了済み＝取り直しは不要
-- 【安全ガード】対象が想定と違えば（件数が8以外・契約が違う）例外で止まり何も変更されない
-- 【戻し方】取消履歴の prev_* から復元（payer_id/prev_payer_checked_at/prev_receiver_checked_at/prev_completed_at と orig_* パス）、payroll_finalized は
--   insert into payroll_finalized(year_month, corporation_id) select '2026-10', sc.corporation_id from smaregi_contracts sc where sc.is_default on conflict do nothing;

-- ■事前（読み取り）
select count(*) filter (where payer_checked_at is not null) as 渡した側, count(*) filter (where receiver_checked_at is not null) as 受取側,
       count(*) filter (where completed_at is not null) as 完了, count(*) as 全件
  from sf_cash_handoff_signatures where year_month = '2026-10' and contract_id = 'sez093z1';

do $$
declare n int; v_corp uuid; v_ins int; v_upd int;
begin
  select count(*) into n from sf_cash_handoff_signatures where year_month = '2026-10';
  if n <> 8 then raise exception '停止: 2026-10 のサイン記録が % 件です（想定8件）。何も変更していません', n; end if;
  if exists (select 1 from sf_cash_handoff_signatures where year_month = '2026-10' and contract_id <> 'sez093z1') then
    raise exception '停止: 2026-10 にトーホー以外の契約の記録があります。何も変更していません';
  end if;
  select sc.corporation_id into v_corp from smaregi_contracts sc where sc.contract_id = 'sez093z1';

  insert into sf_cash_handoff_cancellations(user_id, year_month, contract_id, corporation_id, cancelled_by, reason,
      prev_payer_id, prev_payer_checked_at, prev_receiver_checked_at, prev_completed_at, archived_paths, paid_at_reset)
  select s.user_id, s.year_month, s.contract_id, v_corp, null,
         '9月分を10月分として誤サイン（管理作業による一括取消・ユーザー確認済み）',
         s.payer_id, s.payer_checked_at, s.receiver_checked_at, s.completed_at,
         jsonb_build_object('orig_payer_signature', s.payer_signature_path, 'orig_receiver_signature', s.receiver_signature_path, 'orig_handoff_photo', s.handoff_photo_path),
         0
    from sf_cash_handoff_signatures s
   where s.year_month = '2026-10' and s.contract_id = 'sez093z1'
     and (s.payer_checked_at is not null or s.receiver_checked_at is not null or s.completed_at is not null);
  get diagnostics v_ins = row_count;

  update sf_cash_handoff_signatures set
      payer_id = null, payer_checked_at = null, payer_signature_path = null, handoff_photo_path = null,
      receiver_checked_at = null, receiver_signature_path = null, completed_at = null, updated_at = now()
   where year_month = '2026-10' and contract_id = 'sez093z1'
     and (payer_checked_at is not null or receiver_checked_at is not null or completed_at is not null);
  get diagnostics v_upd = row_count;
  if v_ins <> v_upd or v_ins <> 8 then raise exception '停止: 履歴%件・更新%件（想定8件ずつ）。全て取り消します', v_ins, v_upd; end if;

  delete from payroll_finalized where year_month = '2026-10' and corporation_id = v_corp and finalized_by is null;
end $$;

-- ■事後（読み取り）: サイン 8→0、取消履歴 0→8、2026-10 の確定の印は無し、2026-08・09 は残る
select (select count(*) from sf_cash_handoff_signatures where year_month = '2026-10' and (payer_checked_at is not null or receiver_checked_at is not null or completed_at is not null)) as サイン残り,
       (select count(*) from sf_cash_handoff_cancellations where year_month = '2026-10') as 取消履歴,
       (select count(*) from payroll_finalized where year_month = '2026-10') as 確定の印_10月,
       (select string_agg(year_month, ',' order by year_month) from payroll_finalized) as 確定の印_全月;
