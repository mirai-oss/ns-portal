-- 所属の比較RPC(hr_staff_store_status・担当B作)を、予約済みの店舗対応（例: LiveGateの黒霧屋=11/1開始）も使うよう修正（担当D・2026-10-17）
-- 契約ごとに「今日の対応が無ければ、これから有効になる最も早い対応の開始日」で判定する。それ以外の挙動は変えない。
-- rollback: 変更前の定義は supabase/*hr*status*.sql（担当B）を再適用
CREATE OR REPLACE FUNCTION public.hr_staff_store_status(p_user uuid DEFAULT NULL::uuid, p_only_diff boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_out jsonb; v_today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (is_master or role in ('CEO','HQ'))) then
    raise exception '権限がありません（本部・社長・マスターのみ）';
  end if;
  with lk as (
    select l.user_id, l.contract_id, l.smaregi_staff_id, c.label, c.corporation_hint, c.is_default
      from employee_smaregi_links l
      join smaregi_contracts c on c.contract_id = l.contract_id and c.is_active
     where (p_user is null or l.user_id = p_user)
       and (l.effective_to is null or l.effective_to >= v_today)
  ),
  -- 契約ごとの基準日: 今日の対応があれば今日。無ければ「これから有効になる最も早い対応の開始日」（運営変更の前に先行登録した人を判定できるように）
  asof as (
    select c.contract_id,
      case when exists (select 1 from store_external_mappings e
                         where e.source_system = 'smaregi_timecard' and coalesce(e.is_active, true)
                           and (e.effective_to is null or e.effective_to >= v_today) and (e.effective_from is null or e.effective_from <= v_today)
                           and ((e.corporation_hint is not null and e.corporation_hint = c.corporation_hint) or (e.corporation_hint is null and c.is_default)))
           then v_today
           else coalesce((select min(e.effective_from) from store_external_mappings e
                           where e.source_system = 'smaregi_timecard' and coalesce(e.is_active, true) and e.effective_from > v_today
                             and e.corporation_hint is not null and e.corporation_hint = c.corporation_hint), v_today) end as d
      from smaregi_contracts c where c.is_active
  ),
  mp as (
    select c.contract_id, e.external_store_id::text as sm_store, e.store_id
      from smaregi_contracts c
      join asof a on a.contract_id = c.contract_id
      join store_external_mappings e
        on e.source_system = 'smaregi_timecard' and coalesce(e.is_active, true)
       and (e.effective_to is null or e.effective_to >= a.d)
       and (e.effective_from is null or e.effective_from <= a.d)
       and ((e.corporation_hint is not null and e.corporation_hint = c.corporation_hint) or (e.corporation_hint is null and c.is_default))
     where c.is_active
  ),
  sm as (
    select lk.user_id, lk.contract_id, s.smaregi_store_id, mp.store_id
      from lk
      join smaregi_staff_stores_snapshot s on s.contract_id = lk.contract_id and s.smaregi_staff_id = lk.smaregi_staff_id
      left join smaregi_store_ignore ig on ig.contract_id = s.contract_id and ig.store_id = s.smaregi_store_id
      left join mp on mp.contract_id = s.contract_id and mp.sm_store = s.smaregi_store_id
     where ig.store_id is null
  ),
  per as (
    select lk.*,
      coalesce((select array_agg(distinct us.store_id) from user_stores us
                 where us.user_id = lk.user_id
                   and exists (select 1 from mp where mp.contract_id = lk.contract_id and mp.store_id = us.store_id)), array[]::uuid[]) as portal_ids,
      coalesce((select array_agg(distinct sm.store_id) from sm
                 where sm.user_id = lk.user_id and sm.contract_id = lk.contract_id and sm.store_id is not null), array[]::uuid[]) as smaregi_ids,
      coalesce((select array_agg(distinct g.store_id) from staff_store_sync g
                 where g.user_id = lk.user_id and g.contract_id = lk.contract_id), array[]::uuid[]) as ledger_ids,
      coalesce((select jsonb_agg(distinct sm.smaregi_store_id) from sm
                 where sm.user_id = lk.user_id and sm.contract_id = lk.contract_id and sm.store_id is null), '[]'::jsonb) as unmapped,
      (select max(fetched_at) from smaregi_staff_stores_snapshot x where x.contract_id = lk.contract_id) as snapshot_at
    from lk
  ),
  rows_ as (
    select per.*, u.name,
      (per.portal_ids <@ per.smaregi_ids and per.smaregi_ids <@ per.portal_ids) as in_sync
      from per join users u on u.id = per.user_id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', r.user_id, 'name', r.name, 'contract_id', r.contract_id, 'label', r.label,
      'smaregi_staff_id', r.smaregi_staff_id, 'snapshot_at', r.snapshot_at, 'in_sync', r.in_sync,
      'portal', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name) order by st.sort_order), '[]'::jsonb) from stores st where st.id = any(r.portal_ids)),
      'smaregi', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name) order by st.sort_order), '[]'::jsonb) from stores st where st.id = any(r.smaregi_ids)),
      'only_portal', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name)), '[]'::jsonb) from stores st where st.id = any(r.portal_ids) and not (st.id = any(r.smaregi_ids))),
      'only_smaregi', (select coalesce(jsonb_agg(jsonb_build_object('id', st.id, 'name', st.name)), '[]'::jsonb) from stores st where st.id = any(r.smaregi_ids) and not (st.id = any(r.portal_ids))),
      'unmapped', r.unmapped,
      'changed_side', case
          when r.in_sync then 'none'
          when r.portal_ids is distinct from r.ledger_ids and r.smaregi_ids is distinct from r.ledger_ids then 'both'
          when r.portal_ids is distinct from r.ledger_ids then 'portal'
          when r.smaregi_ids is distinct from r.ledger_ids then 'smaregi'
          else 'unknown' end
    ) order by r.name), '[]'::jsonb)
    into v_out
    from rows_ r
   where (not p_only_diff) or (not r.in_sync);
  return v_out;
end;
$function$
;
