-- 2026-11-12_wage_external_changes.sql を外す  ★実行は別途承認
--   先に: スイッチ wage_import_hold を false に戻し、Edge Function smaregi-sync が旧い版（または false で動く版）であること。
--   控え（wage_external_changes）は消える。未解決（open）が残っているときは止まる（先に控えを取ること）。
do $$
declare n int;
begin
  if coalesce((select (value ->> 'wage_import_hold')::boolean from app_settings where key = 'employee_change'), false) then raise exception 'スイッチ wage_import_hold が true です。先に false に戻してください'; end if;
  if to_regclass('public.wage_external_changes') is not null then
    execute 'select count(*) from wage_external_changes where status = ''open''' into n;
    if n > 0 then raise exception '未解決の外部変更が % 件あります。先に控えを取り、解決してください', n; end if;
  end if;
end $$;
-- 一覧の関数を、足す前の定義に戻す
CREATE OR REPLACE FUNCTION public.hr_sync_status_issues()
 RETURNS TABLE(user_id uuid, cat text, key text, label text, since timestamp with time zone, has_task boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- 承認待ち
  select q.user_id, 'approval_pending', 'pcr:' || q.id, '変更申請の承認待ち（' || case q.field when 'name' then '氏名' when 'kana' then 'フリガナ' when 'phone' then '電話番号' when 'address' then '住所' when 'bank_account' then '給与振込口座'
           when 'contact_email' then '連絡用メール' when 'id_document' then '身分証明書' when 'wage' then '賃金' else q.field end || '）', q.requested_at, q.hq_task_id is not null
    from profile_change_requests q where q.status = 'pending' and q.apply_status not in ('blocked_exported', 'blocked_finalized')
  union all
  select r.user_id, 'approval_pending', 'hcr:' || r.id, '異動・退職などの申請の承認待ち', r.requested_at, false from hr_change_requests r where r.status = 'pending' and r.user_id is not null
  union all
  select c.user_id, 'approval_pending', 'commute:' || c.user_id, '交通費（通勤経路）の承認待ち', c.submitted_at, false from employee_commute c where c.submitted_at is not null and c.approved_at is null and c.recheck_required_at is null
  -- 未同期（承認・登録は済んだが、スマレジ等にまだ反映されていない）
  union all
  select w.user_id, 'unsynced', 'wage:' || w.id, '賃金がスマレジに未反映（適用開始日 ' || w.effective_date || '）', w.updated_at, false from employee_wage_settings w where w.sync_status = 'pending'
  union all
  select s.user_id, 'unsynced', 'commute_setting:' || s.id, '交通費の設定がスマレジに未反映', s.updated_at, false from employee_commute_settings s where s.sync_status in ('pending', 'queued')
  union all
  select x.user_id, 'unsynced', 'tax:' || x.user_id, '源泉・扶養の設定がスマレジに未反映', x.updated_at, false from employee_tax_settings x where x.sync_status in ('pending', 'queued')
  union all
  select y.user_id, 'unsynced', 'year_end:' || y.user_id || ':' || y.target_year, '年末調整の情報がスマレジに未反映', y.updated_at, false from employee_year_end y where y.sync_status in ('pending', 'queued')
  union all
  select p.user_id, 'unsynced', 'profile:' || p.user_id, '従業員情報がスマレジに未反映', p.updated_at, false from employee_profiles p where p.smaregi_sync_status = 'pending'
  union all
  select r.user_id, 'unsynced', 'hcr_sync:' || r.id, '異動・退職の承認内容がスマレジに未反映', r.approved_at, false from hr_change_requests r where r.status = 'approved' and r.sync_status = 'unsynced' and r.user_id is not null
  -- 同期エラー・未反映で止まっているもの
  union all
  select w.user_id, 'sync_error', 'wage:' || w.id, '賃金のスマレジ同期がエラー（適用開始日 ' || w.effective_date || '）', w.updated_at, false from employee_wage_settings w where w.sync_status = 'error'
  union all
  select s.user_id, 'sync_error', 'commute_setting:' || s.id, '交通費の設定のスマレジ同期がエラー', s.updated_at, false from employee_commute_settings s where s.sync_status = 'error'
  union all
  select x.user_id, 'sync_error', 'tax:' || x.user_id, '源泉・扶養の設定のスマレジ同期がエラー', x.updated_at, false from employee_tax_settings x where x.sync_status = 'error'
  union all
  select y.user_id, 'sync_error', 'year_end:' || y.user_id || ':' || y.target_year, '年末調整の情報のスマレジ同期がエラー', y.updated_at, false from employee_year_end y where y.sync_status = 'error'
  union all
  select p.user_id, 'sync_error', 'profile:' || p.user_id, '従業員情報のスマレジ同期がエラー', p.updated_at, false from employee_profiles p where p.smaregi_sync_status = 'error'
  union all
  select r.user_id, 'sync_error', 'hcr_sync:' || r.id, '異動・退職のスマレジ同期がエラー', r.updated_at, false from hr_change_requests r where r.status = 'approved' and r.sync_status = 'error' and r.user_id is not null
  union all
  select q.user_id, 'sync_error', 'pcr_blocked:' || q.id, case when q.apply_status = 'blocked_exported' then '口座変更が未反映（決めた支給回は振込データ出力済み）' else '賃金変更が未反映（適用開始月の給与が確定済み）' end, q.requested_at, false
    from profile_change_requests q where q.status in ('pending', 'approved') and q.apply_status in ('blocked_exported', 'blocked_finalized')
  union all
  select h.user_id, 'sync_error', 'transfer_hold:' || h.year_month || ':' || h.user_id, h.year_month || ' 月分の振込データから除外中（振込漏れに注意）', h.created_at, true
    from payroll_transfer_holds h where h.status in ('held', 'ready')
  -- 情報不一致（読み取りの照合で見つかったもの。既存の所属照合と、照合結果の表）
  union all
  select m.user_id, 'mismatch', 'store:' || m.user_id || ':' || m.contract_id, '所属店舗がスマレジと不一致', m.detected_at, false from staff_store_mismatch m
  union all
  select m.user_id, 'mismatch', 'mm:' || m.id, case m.kind when 'wage' then '賃金がスマレジと不一致' when 'store' then '所属店舗がスマレジと不一致' when 'commute' then '交通費の設定がスマレジと不一致' when 'tax' then '源泉・扶養の設定がスマレジと不一致'
           when 'name' then '氏名が他システムと不一致' when 'address' then '住所が他システムと不一致' when 'active' then '在籍の状態がスマレジと不一致' else '社内情報管理システムの写しと不一致' end, m.detected_at, false
    from employee_sync_mismatches m where m.resolved_at is null
  -- 交通費の再確認待ち（住所・最寄り駅・所属・雇用形態の変更で起動したもの）
  union all
  select e.user_id, 'commute_recheck', 'effect:' || e.id, '交通費の再確認待ち（' || array_to_string(e.reasons, '・') || 'の変更）', e.created_at, false from employee_change_effects e where e.effect_key = 'commute_recheck' and e.status in ('pending', 'in_progress')
$function$;

drop function if exists hr_wage_external_list(boolean, uuid);
drop function if exists hr_wage_external_report(text, uuid[], jsonb, text);
drop function if exists wage_initial_import_users(text, uuid[]);
drop table if exists wage_external_changes;
update app_settings set value = value - 'wage_import_hold' where key = 'employee_change';
