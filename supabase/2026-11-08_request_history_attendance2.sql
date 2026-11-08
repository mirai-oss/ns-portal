-- =============================================================
-- 2026-11-08（2）申請履歴の「勤怠」を全部載せる: フォーム申請（sf_attendance_requests）に加えて
--   ・勤怠確認アラートからの修正／打刻削除（sf_attendance_alerts: fix_requested→approved/rejected）  ref_id='alert:<id>'
--   ・スマレジ・タイムカードでの直接修正の検知（sf_attendance_smaregi_changes）                     ref_id='change:<id>'（状態 unacked/直接）
-- ユーザー指示: 「アラートからでも修正したものは全てこちらの勤怠の履歴に載せて。スマレジから直接修正があった場合も履歴に載せてアラートを出して」
-- 承認待ち件数（request_pending_counts）の attendance にはアラートの承認待ち（fix_requested）も含める。直接修正の未確認は別 kind 'attendance_change'。
-- 2026-11-08_request_history_attendance.sql の全文に union を 2 つ足したもの（他の種類は無変更）
-- ※ 先に 2026-11-08_attendance_delete_request.sql（sf_attendance_alerts.request_kind）を適用すること
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
    -- 2026-11-08(2) 勤怠確認アラートからの修正・打刻削除（店長の申請→マスター承認）
    select 'attendance'::text, al.requested_at, coalesce(aru.name, '（不明）')::text,
           (case when al.request_kind = 'delete' then '🗑 打刻削除（アラートから）　' else '✏️ 勤怠修正（アラートから）　' end
            || public.sf_attendance_alert_summary(al)
            || case when al.request_kind = 'delete' then '' else
                 '／修正後 ' || to_char(al.proposed_clock_in at time zone 'Asia/Tokyo', 'HH24:MI') || '−'
                 || case when (al.proposed_clock_out at time zone 'Asia/Tokyo')::date > (al.proposed_clock_in at time zone 'Asia/Tokyo')::date then '翌' else '' end
                 || to_char(al.proposed_clock_out at time zone 'Asia/Tokyo', 'HH24:MI')
                 || '（' || public.sf_attendance_break_text(al.proposed_break_start_1, al.proposed_break_end_1, al.proposed_break_start_2, al.proposed_break_end_2) || '）' end
            || '／理由: ' || coalesce(al.fix_reason, '')
            || case when al.status = 'approved' and al.smaregi_sync_status = 'failed' then '／⚠️ スマレジ未反映（' || coalesce(al.smaregi_error, '') || '）'
                    when al.status = 'approved' and al.smaregi_sync_status = 'synced' then '／スマレジ反映済み' else '' end)::text,
           null::numeric, case al.status when 'fix_requested' then 'pending' else al.status end::text, al.decided_at, adu.name::text, ast2.name::text, ('alert:' || al.id)::text
    from public.sf_attendance_alerts al
      left join public.users aru on aru.id = al.requested_by
      left join public.users adu on adu.id = al.decided_by
      left join public.stores ast2 on ast2.id = al.store_id
    where al.status in ('fix_requested', 'approved', 'rejected') and al.requested_at is not null and al.requested_at >= v_from and al.requested_at < v_to
    union all
    -- 2026-11-08(2) スマレジ・タイムカードで直接修正された検知（承認は無い。Slack の「○ 確認した」で確認済みになる）
    select 'attendance'::text, c.detected_at, '（スマレジで直接修正）'::text,
           ('✏️ スマレジ直接修正　' || to_char(c.work_date, 'FMMM/FMDD') || '（' || (array['日','月','火','水','木','金','土'])[extract(dow from c.work_date)::int + 1] || '）　'
            || coalesce(cs.name, '') || '　' || coalesce(cu.name, '') || '　' || coalesce(c.diff_text, ''))::text,
           null::numeric, case c.status when 'acknowledged' then 'direct' else 'unacked' end::text, c.acknowledged_at, cau.name::text, cs.name::text, ('change:' || c.id)::text
    from public.sf_attendance_smaregi_changes c
      left join public.users cu on cu.id = c.user_id
      left join public.users cau on cau.id = c.acknowledged_by
      left join public.stores cs on cs.id = c.store_id
    where c.detected_at >= v_from and c.detected_at < v_to
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
    select 'attendance'::text, (select count(*) from public.sf_attendance_requests a where a.status = 'pending') + (select count(*) from public.sf_attendance_alerts al where al.status = 'fix_requested')   -- 2026-11-08(2) フォーム申請＋アラートからの修正/削除の承認待ち
    union all
    select 'attendance_change'::text, count(*) from public.sf_attendance_smaregi_changes c where c.status = 'open';   -- スマレジ直接修正の未確認（Slack の「○ 確認した」待ち）
end;
$$;
revoke all on function public.request_pending_counts() from public, anon;
grant execute on function public.request_pending_counts() to authenticated;
