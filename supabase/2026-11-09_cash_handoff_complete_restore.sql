-- ============================================================
-- 2026-11-09 担当B（nippo）— cash_handoff_complete の退行修正だけを切り出した独立SQL（U-23/U-24 本体より先に適用）
-- 【状態】事前報告（未適用）。1ファイル・1トランザクション（SQLエディタで一括実行＝途中失敗なら全部なし）
-- 【退行】2026-11-03 のSQLで古い版を土台に作り直し、次の3つが失われていた:
--   (a) 完了済みの再実行で completed_at を上書きしない  (b) 本部タスクのチェックリスト連携（hq_check_payroll_task_item）
--   (c) 対象者が全員完了したときの Lark/Slack 完了通知
--   ここで3つとも復元（11-03で足した契約別の動きは維持）。引数・戻り値・権限は11-03版のまま（画面・他処理への影響なし）
-- 【適用前の安全確認（自動）】本番の現在の定義が「11-03で適用した版」と一致するかを、関数本体の指紋(md5)・引数・SECURITY DEFINER・
--   search_path・同名関数の本数で確認。1つでも違えば例外で止まり、何も変更されない（本文は出さず指紋だけ表示）
-- 【影響】hq_check_payroll_task_item は3引数のまま呼ぶ（現状の主キー(year_month,kind)に対応）。U-23本体の適用後は法人ID付きの版に置き換わる
-- 【rollback】11-03版（2026-11-03_payroll_funcs_concurrent_staff.sql の③）で create or replace し直す（ただし3機能が再び失われるので非推奨）
-- ============================================================

do $$
declare r record; n int;
begin
  select count(*) into n from pg_proc where proname = 'cash_handoff_complete' and pronamespace = 'public'::regnamespace;
  if n <> 1 then raise exception '停止: cash_handoff_complete が % 本あります（1本のはず）', n; end if;
  select p.prosrc, pg_get_function_identity_arguments(p.oid) as args, p.prosecdef, p.proconfig, p.proowner::regrole::text as owner
    into r from pg_proc p where p.proname = 'cash_handoff_complete' and p.pronamespace = 'public'::regnamespace;
  if r.args <> 'p_user_id uuid, p_year_month text, p_contract_id text' then
    raise exception '停止: 引数が想定と違います（%）', r.args;
  end if;
  if not r.prosecdef then raise exception '停止: SECURITY DEFINER ではありません'; end if;
  if r.proconfig is null or not ('search_path=public' = any(r.proconfig)) then raise exception '停止: search_path設定が想定と違います（%）', r.proconfig; end if;
  if md5(r.prosrc) <> '6df412788129994c5aa637c796bf672d' then
    raise exception '停止: 本番の本文の指紋が11-03版と一致しません（本番=%・想定=6df41278…。長さ=%）。担当Bに報告してください', md5(r.prosrc), length(r.prosrc);
  end if;
end $$;

create or replace function public.cash_handoff_complete(p_user_id uuid, p_year_month text, p_contract_id text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_row sf_cash_handoff_signatures%rowtype; v_synced_rows integer := 0; v_contract text; v_tenant text;
  v_already_done boolean; v_uname text; v_total int; v_done int; v_corp_name text; v_def text;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ','TENCHO','TEAM'))) then
    raise exception '権限がありません';
  end if;
  select sc.contract_id into v_def from smaregi_contracts sc where sc.is_default limit 1;
  v_contract := coalesce(p_contract_id, v_def);
  select * into v_row from sf_cash_handoff_signatures where user_id = p_user_id and year_month = p_year_month and contract_id = v_contract;
  if v_row.id is null then raise exception '対象の記録が見つかりません'; end if;
  if v_row.payer_checked_at is null or v_row.receiver_checked_at is null then
    raise exception '渡した側・受け取った側、両方の確認が必要です';
  end if;

  v_already_done := v_row.completed_at is not null;                                    -- (a) 復元: 完了済みの再実行で上書きしない
  update sf_cash_handoff_signatures set completed_at = coalesce(completed_at, now()), updated_at = now() where id = v_row.id;

  select case sc.corporation_hint when 'toho' then 'default' else sc.corporation_hint end, c.name
    into v_tenant, v_corp_name
    from smaregi_contracts sc left join corporations c on c.id = sc.corporation_id where sc.contract_id = v_contract;
  begin
    update payroll_journal_records set paid_at = now(), paid_by = auth.uid()
     where user_id = p_user_id and year_month = p_year_month and paid_at is null
       and (v_tenant is null or tenant_id = v_tenant);
    get diagnostics v_synced_rows = row_count;
  exception when undefined_table then v_synced_rows := 0;
  end;

  if not v_already_done then
    begin                                                                              -- (b) 復元: 本部タスクのチェックリスト連携
      select name into v_uname from users where id = p_user_id;
      if v_uname is not null then perform hq_check_payroll_task_item(p_year_month, 'cash', v_uname); end if;
    exception when others then null;                                                   -- 本部タスク未発行等でも手渡しの完了自体は止めない
    end;
    begin                                                                              -- (c) 復元: この月×この契約の対象者が全員完了したら通知
      select count(distinct pba.user_id) into v_total
        from payroll_bank_accounts pba join users u on u.id = pba.user_id and u.is_active
       where pba.payment_method = 'cash'
         and (exists (select 1 from sf_payroll_sync sp where sp.user_id = pba.user_id and sp.year_month = p_year_month and sp.contract_id = v_contract)
              or (v_contract = v_def and not exists (select 1 from sf_payroll_sync sp where sp.user_id = pba.user_id and sp.year_month = p_year_month)));
      select count(distinct s.user_id) into v_done
        from sf_cash_handoff_signatures s
        join payroll_bank_accounts pba on pba.user_id = s.user_id and pba.payment_method = 'cash'
        join users u on u.id = s.user_id and u.is_active
       where s.year_month = p_year_month and s.contract_id = v_contract and s.completed_at is not null;
      if v_total > 0 and v_total = v_done then
        perform notify_lark('💴 現金手渡し完了：'||p_year_month||'分（'||coalesce(v_corp_name,'')||'）の現金手渡し対象者 全'||v_total||'名の受け渡しが完了しました（nippo「現金手渡し・サイン」）');
      end if;
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', true, 'journal_marked_paid', v_synced_rows > 0);
end;
$function$;
-- 権限は11-03版と同じ（authenticated のみ。PUBLIC/anon なし）に揃える
revoke all on function public.cash_handoff_complete(uuid, text, text) from public, anon;
grant execute on function public.cash_handoff_complete(uuid, text, text) to authenticated;

-- ===== 適用後の確認（無害・実データの完了は押さない）=====
select
  (select count(*) from pg_proc where proname = 'cash_handoff_complete' and pronamespace = 'public'::regnamespace) as 関数の本数,
  p.prosecdef as security_definer, p.proconfig, p.proowner::regrole::text as owner,
  p.prosrc like '%hq_check_payroll_task_item%' as チェック連携あり,
  p.prosrc like '%notify_lark%'              as 完了通知あり,
  p.prosrc like '%coalesce(completed_at, now())%' as 上書きガードあり
from pg_proc p where p.proname = 'cash_handoff_complete' and p.pronamespace = 'public'::regnamespace;
select a.grantee::regrole::text as grantee, a.privilege_type
  from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
 where p.proname = 'cash_handoff_complete' and p.pronamespace = 'public'::regnamespace order by 1;
