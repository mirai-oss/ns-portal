-- =============================================================
-- 2026-11-08 申請履歴（tori-dashboard「管理・権限 → 申請履歴」）に勤怠の追加・修正申請（sf_attendance_requests）を載せる
-- ユーザー指示: 「先ほど作ったフォームの URL とか申請もこちらに追加して。申請履歴も追いたいのと、承認も管理システムからでもできるように」
--   request_history(p_month)   … kind='attendance' の行を union（内容=sf_attendance_request_summary＋理由、状態=pending/approved/rejected/cancelled）
--   request_pending_counts()   … kind='attendance' の承認待ち件数（左メニューの未読バッジ）
--   承認・却下は EF attendance-request の op=decide（ログインユーザー＝マスターのみ。RPC sf_attendance_request_decide に p_via='portal'）
-- 既存の定義（2026-11-04 / 2026-11-05）に union を 1 つ足しただけ。他の種類は無変更。
-- =============================================================

create or replace function public.request_history(p_month text)
returns table (kind text, occurred_at timestamptz, requester text, summary text, amount numeric, status text,
               decided_at timestamptz, decided_by text, store text, ref_id text)
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_from timestamptz; v_to timestamptz;
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  if p_month is null or p_month !~ '^\d{4}-\d{2}$' then raise exception 'bad month'; end if;
  v_from := ((p_month || '-01')::date)::timestamp at time zone 'Asia/Tokyo';
  v_to := (((p_month || '-01')::date + interval '1 month')::date)::timestamp at time zone 'Asia/Tokyo';
  return query
    select 'cost_transfer'::text, r.submitted_at, coalesce(nullif(r.requester_name, ''), '（申請者の記録なし）')::text,
           (r.from_store || '→' || r.to_store || '／' || coalesce((select string_agg(i ->> 'name', '・') from jsonb_array_elements(r.items) i), '') || '（' || r.transfer_date || '）')::text,
           r.total::numeric, r.status::text, r.approved_at, nullif(r.approver, '')::text, r.from_store::text, r.id::text
    from public.cost_transfer_requests r where r.submitted_at >= v_from and r.submitted_at < v_to
    union all
    select 'spot_labor_request'::text, q.submitted_at, coalesce(nullif(q.requester_name, ''), '（不明）')::text,
           (q.store_name || '／' || q.work_date || '／' || q.kind || case when q.headcount is not null then '／' || q.headcount || '人' else '' end || case when coalesce(q.note, '') <> '' then '／' || q.note else '' end)::text,
           q.amount::numeric, q.status::text, q.approved_at, nullif(q.approver, '')::text, q.store_name::text, q.id::text
    from public.spot_labor_requests q where q.submitted_at >= v_from and q.submitted_at < v_to
    union all
    select 'retirement'::text, h.requested_at, coalesce(h.requester_name, rq.name, '（不明）')::text,
           (coalesce(tu.name, '') || 'さん 退職日 ' || h.effective_date || '（' || coalesce(st.name, '') || '）')::text,
           null::numeric, h.status::text, coalesce(h.approved_at, h.rejected_at), coalesce(ap.name, rj.name)::text, st.name::text, h.id::text
    from public.hr_change_requests h
      left join public.users rq on rq.id = h.requested_by
      left join public.users tu on tu.id = h.user_id
      left join public.stores st on st.id = h.store_id
      left join public.users ap on ap.id = h.approved_by
      left join public.users rj on rj.id = h.rejected_by
    where h.kind = 'retirement' and h.requested_at >= v_from and h.requested_at < v_to
    union all
    select 'expense'::text, e.applied_at, coalesce(au.name, '（不明）')::text,
           (coalesce(es.name, '') || '／' || e.use_date || '／' || coalesce(ec.name, '') || '／' || coalesce(e.purpose, '') || case when coalesce(e.memo, '') <> '' then '／' || e.memo else '' end)::text,
           e.amount::numeric, e.status::text, e.decided_at,
           (select u2.name from public.expense_approvals a2 join public.users u2 on u2.id = a2.approver_id where a2.request_id = e.id order by a2.acted_at desc limit 1)::text,
           es.name::text, e.id::text
    from public.expense_requests e
      left join public.users au on au.id = e.applicant_id
      left join public.stores es on es.id = e.store_id
      left join public.expense_categories ec on ec.id = e.category_id
    where e.status <> 'draft' and e.applied_at is not null and e.applied_at >= v_from and e.applied_at < v_to
    union all
    -- 2026-11-08 勤怠の追加・修正申請（Slack / kintai.html から）。内容は Slack と同じ文（種類・日付・店舗・従業員・時間・休憩）＋理由
    select 'attendance'::text, a.requested_at, coalesce(ru.name, '（不明）')::text,
           (public.sf_attendance_request_summary(a) || '／理由: ' || coalesce(a.reason, '')
            || case when a.status = 'approved' and a.smaregi_sync_status = 'failed' then '／⚠️ スマレジ未反映（' || coalesce(a.smaregi_error, '') || '）'
                    when a.status = 'approved' and a.smaregi_sync_status = 'synced' then '／スマレジ反映済み' else '' end)::text,
           null::numeric, a.status::text, a.decided_at, du.name::text, ast.name::text, a.id::text
    from public.sf_attendance_requests a
      left join public.users ru on ru.id = a.requested_by
      left join public.users du on du.id = a.decided_by
      left join public.stores ast on ast.id = a.store_id
    where a.requested_at >= v_from and a.requested_at < v_to
    union all
    select l.kind::text, l.occurred_at, coalesce(nullif(l.requester_name, ''), l.entered_by, '（不明）')::text,
           (coalesce(l.summary, '') || case l.action when 'delete' then '【削除】' when 'update' then '【修正】' else '' end)::text,
           l.amount::numeric, 'direct'::text, null::timestamptz, l.entered_by::text, l.store_name::text, l.id::text
    from public.request_log l where l.occurred_at >= v_from and l.occurred_at < v_to
    order by 2 desc;
end;
$$;
revoke all on function public.request_history(text) from public, anon;
grant execute on function public.request_history(text) to authenticated;

create or replace function public.request_pending_counts() returns table (kind text, n bigint)
language plpgsql stable security definer set search_path to 'public'
as $$
begin
  if not public._is_request_admin() then raise exception 'forbidden'; end if;
  return query
    select 'cost_transfer'::text, count(*) from public.cost_transfer_requests c where c.status = 'pending'
    union all
    select 'spot_labor_request'::text, count(*) from public.spot_labor_requests q where q.status = 'pending'
    union all
    select 'retirement'::text, count(*) from public.hr_change_requests h where h.kind = 'retirement' and h.status = 'pending'
    union all
    select 'expense'::text, count(*) from public.expense_requests e where e.status = 'pending'
    union all
    select 'quote'::text, count(*) from public.quote_requests z where z.status in ('pending', 'on_hold')   -- 保留中も未読バッジに残す
    union all
    select 'attendance'::text, count(*) from public.sf_attendance_requests a where a.status = 'pending';   -- 2026-11-08 勤怠の追加・修正申請
end;
$$;
revoke all on function public.request_pending_counts() from public, anon;
grant execute on function public.request_pending_counts() to authenticated;
