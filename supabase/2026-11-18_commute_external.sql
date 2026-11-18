-- 2026-11-18 案3: スマレジの交通費（事業所別を含む）を、読み取って「未承認」で保留し、社長・マスターが取り込む。設計書 §2
--   ① commute_external_changes: スマレジにだけある／違う交通費の設定の控え（読み取り専用の照合の結果。正式な設定には入れない）
--   ② hr_commute_external_record(p_items, p_checked): 照合の結果を記録（サービスのみ）。照合済みの人で、いまは一致している控えは自動で閉じる
--   ③ hr_commute_external_import(p_id, p_reason): 社長・マスターだけ。控えの内容を employee_commute_settings に入れる（スマレジへは何も送らない・反映済みの印つき）。理由が必須
--   ④ hr_sync_status_issues: 「同期・承認の状況」に未承認の交通費を出す（本番の定義を取得して末尾に1段足しただけ）
--   rollback: 2026-11-18_commute_external_rollback.sql
create table if not exists commute_external_changes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null, contract_id text not null, effective_date date not null,
  pay_type text not null check (pay_type in ('per_shift','per_day','monthly')),
  scope text not null check (scope in ('all','per_store')),
  amount integer, store_amounts jsonb, cap_amount integer,
  kind text not null check (kind in ('new_row','changed')),
  system_id uuid,                -- 管理システム側の行（changed のとき）
  smaregi_value jsonb,           -- スマレジ側の行そのまま
  status text not null default 'open' check (status in ('open','approved','resolved_match','dismissed')),
  first_detected_at timestamptz not null default now(), last_seen_at timestamptz not null default now(), seen_count integer not null default 1,
  resolved_at timestamptz, resolved_by uuid, resolve_note text
);
create unique index if not exists commute_external_changes_open_uq on commute_external_changes(user_id, contract_id, effective_date, pay_type) where status = 'open';
alter table commute_external_changes enable row level security;

create or replace function public.hr_commute_external_record(p_items jsonb, p_checked uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare it jsonb; n_new int := 0; n_closed int := 0;
begin
  if not (onboarding_is_service() or hq_can_manage()) then raise exception '権限がありません'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    insert into commute_external_changes(user_id, contract_id, effective_date, pay_type, scope, amount, store_amounts, cap_amount, kind, system_id, smaregi_value)
    values ((it ->> 'user_id')::uuid, it ->> 'contract_id', (it ->> 'effective_date')::date, it ->> 'pay_type', it ->> 'scope', nullif(it ->> 'amount','')::int,
            it -> 'store_amounts', nullif(it ->> 'cap_amount','')::int, it ->> 'kind', nullif(it ->> 'system_id','')::uuid, it -> 'smaregi_value')
    on conflict (user_id, contract_id, effective_date, pay_type) where status = 'open'
    do update set last_seen_at = now(), seen_count = commute_external_changes.seen_count + 1, scope = excluded.scope, amount = excluded.amount, store_amounts = excluded.store_amounts,
                  cap_amount = excluded.cap_amount, kind = excluded.kind, system_id = excluded.system_id, smaregi_value = excluded.smaregi_value;
    n_new := n_new + 1;
  end loop;
  -- 照合した人で、今回の結果に出てこない（＝一致した）控えは閉じる
  update commute_external_changes c set status = 'resolved_match', resolved_at = now(), resolve_note = '照合で一致を確認'
   where c.status = 'open' and c.user_id = any(coalesce(p_checked, '{}'))
     and not exists (select 1 from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i
                      where (i ->> 'user_id')::uuid = c.user_id and i ->> 'contract_id' = c.contract_id and (i ->> 'effective_date')::date = c.effective_date and i ->> 'pay_type' = c.pay_type);
  get diagnostics n_closed = row_count;
  return jsonb_build_object('ok', true, 'recorded', n_new, 'closed', n_closed);
end $$;
revoke all on function public.hr_commute_external_record(jsonb, uuid[]) from public, anon;
grant execute on function public.hr_commute_external_record(jsonb, uuid[]) to authenticated, service_role;

create or replace function public.hr_commute_external_import(p_id uuid, p_reason text, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare c commute_external_changes%rowtype; v_actor uuid;
begin
  if auth.uid() is not null then v_actor := auth.uid(); elsif onboarding_is_service() then v_actor := p_actor; else raise exception '認証が必要です'; end if;
  if v_actor is null or not exists (select 1 from users u where u.id = v_actor and u.is_active and (u.is_master or u.role = 'CEO')) then raise exception '権限がありません（社長・マスターのみ）'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then raise exception '理由を入れてください'; end if;
  select * into c from commute_external_changes where id = p_id for update;
  if not found then raise exception '対象が見つかりません'; end if;
  if c.status <> 'open' then raise exception 'すでに処理済みです（%）', c.status; end if;
  if c.kind = 'changed' and c.system_id is not null then
    update employee_commute_settings set pay_type = c.pay_type, scope = c.scope, amount = c.amount, store_amounts = c.store_amounts, cap_amount = c.cap_amount,
           sync_status = 'synced', sync_error = null, note = coalesce(note || ' / ', '') || 'スマレジの値に合わせた（取り込み）', updated_at = now() where id = c.system_id;
  else
    insert into employee_commute_settings(user_id, contract_id, pay_type, effective_date, scope, amount, store_amounts, cap_amount, cap_unit, sync_status, note, created_by)
    values (c.user_id, c.contract_id, c.pay_type, c.effective_date, c.scope, c.amount, c.store_amounts, c.cap_amount, 'unknown', 'synced', 'スマレジから取り込み', v_actor);
  end if;
  update commute_external_changes set status = 'approved', resolved_at = now(), resolved_by = v_actor, resolve_note = '取り込み（スマレジには何も送っていません）: ' || trim(p_reason) where id = c.id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.hr_commute_external_import(uuid, text, uuid) from public, anon;
grant execute on function public.hr_commute_external_import(uuid, text, uuid) to authenticated, service_role;

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
  -- 2026-11-12: スマレジ側で直接変更された賃金（未承認。正式な賃金にはしていない）
  union all
  select e.user_id, 'mismatch', 'wext:' || e.id,
         '未承認の賃金変更（スマレジで直接' || case e.kind when 'new_row' then '追加された行' when 'amount_changed' then '金額を変更' else '削除された行' end || '・' || case e.division when 0 then '時給' when 1 then '日給' else '月給' end || '・' || coalesce((select st.name from stores st where st.id = e.store_id), '全事業所共通') || '・適用開始日 ' || e.effective_date || '）', e.first_detected_at, false
    from wage_external_changes e where e.status = 'open'
  -- 2026-11-18: スマレジにだけある（または違う）交通費の設定（未承認。正式な設定にはしていない）
  union all
  select c.user_id, 'mismatch', 'cext:' || c.id,
         '未承認の交通費の変更（スマレジの設定' || case c.kind when 'new_row' then 'が管理システムに無い' else 'が管理システムと違う' end || '・' ||
         case c.pay_type when 'per_shift' then '勤務回数ごと' when 'monthly' then '月額' else '勤務日数ごと' end || '・' ||
         case c.scope when 'per_store' then '事業所別' else '全事業所共通' end || '・適用開始日 ' || c.effective_date || '）', c.first_detected_at, false
    from commute_external_changes c where c.status = 'open'
$function$;
