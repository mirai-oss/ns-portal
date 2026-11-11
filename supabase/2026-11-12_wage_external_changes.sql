-- スマレジ側で直接変更された賃金を、正式な賃金として自動登録しない（開発 1・2026-11-12）
--   設計: docs/設計書_従業員情報変更の連動_2026-11-10.md §21（21.1 と 21.3）・§23
--   ★ 本番未適用（開発・テストのみ承認。適用は別途承認）。戻し方: 2026-11-12_wage_external_changes_rollback.sql
--
--   これは「控えの表」と「記録の関数」。取り込みの動きを変えるのは Edge Function smaregi-sync（wage_pull_all / wage_pull）で、
--   スイッチ app_settings.employee_change.wage_import_hold が true のときだけ（既定 false＝これまでどおり全部取り込む）。
--   適用しただけでは何も変わらない（既存の賃金・申請・同期には触れない。足すのは表 1 つ・関数 3 つ・設定の項目 1 つ、作り替えるのは一覧の関数 1 つに 1 段足すだけ）。
--
--   スイッチが true のとき（Edge Function のデプロイ後）:
--     ・スマレジにだけある「いま有効・これから適用」の賃金の行 → 正式な賃金（employee_wage_settings）に入れず、ここに「未承認（open）」で記録
--     ・初期投入だけは、これまでどおり自動で取り込む: 入社したばかりの人だけ（入社手続きの状態・賃金の履歴・承認の状態・連携の履歴を組み合わせて判定。下の 2.）
--     ・スイッチを false に戻しても、未解決（open）の控えがある人は保留を続ける（Edge Function 側。保留中の行を、戻しただけで正式な賃金にしない）
--     ・金額の違い・行の削除も、ここに記録する
--     ・次の照合で違いが無くなっていたら（スマレジ側が戻った・正式に登録された）、自動で「一致を確認」で閉じる
--   承認済みの賃金のスマレジ同期（管理システム → スマレジ）と、入社時の初期賃金登録は変えない。

-- ============ 1. 外部変更の控え ============
create table if not exists wage_external_changes (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null,
  contract_id           text not null,
  division              integer not null,
  store_id              uuid,
  smaregi_store_id      text,
  effective_date        date not null,
  kind                  text not null check (kind in ('new_row', 'amount_changed', 'deleted')),   -- スマレジにだけある行／金額の違い／スマレジから消えた行
  smaregi_wage_apply_id text,
  smaregi_value         jsonb,          -- スマレジ側の値（賃金・休日賃金）。読めるのは本部系だけ
  system_value          jsonb,          -- 管理システム側の値（承認済みの賃金）
  wage_setting_id       uuid,           -- 管理システムの賃金の行（金額の違い・削除のとき）
  status                text not null default 'open' check (status in ('open', 'resolved_match', 'approved', 'reverted', 'dismissed')),
  first_detected_at     timestamptz not null default now(),
  last_seen_at          timestamptz not null default now(),
  seen_count            integer not null default 1,
  source                text,
  resolved_at           timestamptz,
  resolved_by           uuid,
  resolve_note          text,
  request_id            uuid            -- 正式な申請に載せたとき（開発 4）
);
create unique index if not exists wage_external_changes_open_uq on wage_external_changes
  (user_id, contract_id, division, coalesce(store_id, '00000000-0000-0000-0000-000000000000'::uuid), effective_date, kind) where status = 'open';
create index if not exists wage_external_changes_user_idx on wage_external_changes (user_id, status);
alter table wage_external_changes enable row level security;   -- 書くのは関数だけ（書き込みの方針は作らない）
drop policy if exists wage_external_changes_read on wage_external_changes;
create policy wage_external_changes_read on wage_external_changes for select using (hq_can_manage());
update app_settings set value = '{"wage_import_hold": false}'::jsonb || value where key = 'employee_change';

-- ============ 2. 初期投入としてこれまでどおり取り込んでよい人 ============
--   「連携から 14 日以内」だけでは許可しない（2026-11-12 ユーザー指示）。既存の従業員の再連携・法人をまたぐ異動で、未承認の賃金が自動登録されないようにする。
--   次の全部を満たす人だけ（＝入社したばかりで、管理システムに賃金の記録も申請も無い人）:
--     ① 入社手続きの状態: 入社登録が進行中、または完了してから 14 日以内（取り消しは不可。入社登録が無い人は不可）
--     ② 賃金の履歴: 管理システムに賃金が 1 件も無い（どの契約にも。別の法人に賃金がある人＝異動は不可）
--     ③ 承認の状態: 承認待ちの賃金変更の申請が無い／未解決（open）の外部変更の控えが無い
--     ④ 連携の履歴: 終了したスマレジ連携が無い（再連携・異動は不可）／入社登録より 14 日以上前からある連携が無い（既存の従業員は不可）
create or replace function wage_initial_import_users(p_contract text, p_users uuid[])
returns uuid[] language plpgsql stable security definer set search_path = public as $$
begin
  if not (hq_can_manage() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  return coalesce((select array_agg(u) from unnest(p_users) u
    where exists (select 1 from onboarding_workflows f where f.user_id = u
                    and (f.status in ('hired_confirmed', 'form_sent', 'registering') or (f.status = 'completed' and f.completed_at > now() - interval '14 days'))
                    and not exists (select 1 from employee_smaregi_links l where l.user_id = u and (l.effective_to is not null or l.created_at < f.created_at - interval '14 days')))
      and exists (select 1 from employee_smaregi_links l where l.user_id = u and l.contract_id = p_contract)
      and not exists (select 1 from employee_wage_settings w where w.user_id = u)
      and not exists (select 1 from profile_change_requests q where q.user_id = u and q.field = 'wage' and q.status = 'pending')
      and not exists (select 1 from wage_external_changes e where e.user_id = u and e.status = 'open')), '{}');
end $$;

-- ============ 3. 照合の結果を記録する（Edge Function が呼ぶ。スマレジにも、正式な賃金にも書かない） ============
--   p_checked: 今回スマレジを読めた従業員／p_items: 見つかった外部変更 [{user_id, kind, division, store_id, smaregi_store_id, effective_date, smaregi_wage_apply_id, smaregi_value, system_value, wage_setting_id}]
--   読めた人の「未承認（open）」のうち、今回見つからなかったものは「一致を確認」で閉じる
create or replace function hr_wage_external_report(p_contract text, p_checked uuid[], p_items jsonb, p_source text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare it jsonb; v_id uuid; v_new integer := 0; v_seen integer := 0; v_closed integer := 0; v_keep uuid[] := '{}'; v_store uuid;
begin
  -- 呼べるのは Edge Function（サービス）だけ。画面から直接呼んで、未承認の控えを「一致」で閉じることはできない
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    if not ((it ->> 'user_id')::uuid = any(coalesce(p_checked, '{}'))) then continue; end if;
    if it ->> 'kind' not in ('new_row', 'amount_changed', 'deleted') then continue; end if;
    v_store := nullif(it ->> 'store_id', '')::uuid;
    update wage_external_changes set last_seen_at = now(), seen_count = seen_count + 1, smaregi_value = it -> 'smaregi_value', system_value = it -> 'system_value',
           smaregi_wage_apply_id = coalesce(it ->> 'smaregi_wage_apply_id', smaregi_wage_apply_id), wage_setting_id = coalesce(nullif(it ->> 'wage_setting_id', '')::uuid, wage_setting_id)
     where status = 'open' and user_id = (it ->> 'user_id')::uuid and contract_id = p_contract and division = (it ->> 'division')::int
       and coalesce(store_id, '00000000-0000-0000-0000-000000000000'::uuid) = coalesce(v_store, '00000000-0000-0000-0000-000000000000'::uuid)
       and effective_date = (it ->> 'effective_date')::date and kind = it ->> 'kind'
    returning id into v_id;
    if v_id is null then
      insert into wage_external_changes(user_id, contract_id, division, store_id, smaregi_store_id, effective_date, kind, smaregi_wage_apply_id, smaregi_value, system_value, wage_setting_id, source)
      values ((it ->> 'user_id')::uuid, p_contract, (it ->> 'division')::int, v_store, it ->> 'smaregi_store_id', (it ->> 'effective_date')::date, it ->> 'kind', it ->> 'smaregi_wage_apply_id',
              it -> 'smaregi_value', it -> 'system_value', nullif(it ->> 'wage_setting_id', '')::uuid, p_source)
      returning id into v_id;
      v_new := v_new + 1;
    else v_seen := v_seen + 1; end if;
    v_keep := v_keep || v_id;
  end loop;
  update wage_external_changes set status = 'resolved_match', resolved_at = now(), resolve_note = '照合で一致を確認（スマレジ側が戻った、または正式に登録された）'
   where status = 'open' and contract_id = p_contract and user_id = any(coalesce(p_checked, '{}')) and not (id = any(v_keep));
  get diagnostics v_closed = row_count;
  return jsonb_build_object('ok', true, 'new', v_new, 'still_open', v_seen, 'closed', v_closed,
    'open_total', (select count(*) from wage_external_changes where status = 'open'));
end $$;

-- ============ 4. 一覧（本部系だけ。金額はここでだけ見える） ============
create or replace function hr_wage_external_list(p_only_open boolean default true, p_user uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (hq_can_manage() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  return coalesce((select jsonb_agg(x order by x.first_detected_at desc) from (
    select e.id, e.user_id, (select name from users u where u.id = e.user_id) user_name, e.contract_id, e.division, e.store_id, (select name from stores s where s.id = e.store_id) store_name,
           e.effective_date, e.kind, case e.kind when 'new_row' then 'スマレジにだけある行（未承認）' when 'amount_changed' then '金額がスマレジで変更されている' else 'スマレジから行が消えている' end kind_label,
           e.smaregi_value, e.system_value, e.status, e.first_detected_at, e.last_seen_at, e.seen_count, e.resolved_at, e.resolve_note
      from wage_external_changes e
     where (not coalesce(p_only_open, true) or e.status = 'open') and (p_user is null or e.user_id = p_user)
     order by e.first_detected_at desc limit 300) x), '[]'::jsonb);
end $$;

revoke all on function wage_initial_import_users(text, uuid[]), hr_wage_external_report(text, uuid[], jsonb, text), hr_wage_external_list(boolean, uuid) from public, anon, authenticated;
grant execute on function wage_initial_import_users(text, uuid[]), hr_wage_external_list(boolean, uuid) to authenticated, service_role;
grant execute on function hr_wage_external_report(text, uuid[], jsonb, text) to service_role;

-- ============ 5. 「同期・承認の状況」に出す（既存の一覧の関数に 1 段足す。ほかの段は適用時点の本番の定義のまま） ============
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
         '未承認の賃金変更（スマレジで直接' || case e.kind when 'new_row' then '追加された行' when 'amount_changed' then '金額を変更' else '削除された行' end || '・適用開始日 ' || e.effective_date || '）', e.first_detected_at, false
    from wage_external_changes e where e.status = 'open'
$function$;
