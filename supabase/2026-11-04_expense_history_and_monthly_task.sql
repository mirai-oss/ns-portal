-- 【事前報告様式（DB変更）】
-- 目的: ①申請履歴(経営DのRPC request_history)に「経費申請」(expense_requests)を追加（承認・絞り込み・CSVは画面側）。承認待ち件数(request_pending_counts)にも追加。
--       ②毎月、前月分の従業員経費（承認済み・立替・承認日が該当月）を従業員ごとに合計した本部タスク「<M>月分従業員経費」を自動作成（期限=翌月5日・担当=原 美香）。
-- 変更: request_history／request_pending_counts を差し替え（既存列・既存の種類は無変更・経費だけ追加）。新規: hq_expense_monthly_task(p_ym)。
-- ロールバック: request_history/request_pending_counts を 2026-10-05_request_forms.sql / request_pending_counts.sql の定義に戻す・drop function hq_expense_monthly_task.
-- 実行: supabase db query --linked -f supabase/2026-11-04_expense_history_and_monthly_task.sql

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
    select 'expense'::text, count(*) from public.expense_requests e where e.status = 'pending';
end;
$$;
revoke all on function public.request_pending_counts() from public, anon;
grant execute on function public.request_pending_counts() to authenticated;

-- 毎月の従業員経費の本部タスク（冪等・毎日呼んでよい。同月のタスクが既にあれば、未完了の工程の金額だけ更新し、新しい従業員を追加する）
create or replace function public.hq_expense_monthly_task(p_ym text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_claims jsonb; v_ym text; v_from date; v_to date; v_key text; v_task uuid; v_assignee uuid; v_due date; v_title text;
  rec record; v_title2 text; i int := 0; n_new int := 0; n_upd int := 0; v_cnt int; v_pending int;
begin
  begin v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb; exception when others then v_claims := null; end;
  if coalesce(v_claims->>'role', '') <> 'service_role' and not public._is_request_admin() then return jsonb_build_object('ok', false, 'error', 'forbidden'); end if;
  v_ym := coalesce(nullif(btrim(p_ym), ''), to_char(((now() at time zone 'Asia/Tokyo')::date - interval '1 month'), 'YYYY-MM'));
  if v_ym !~ '^\d{4}-(0[1-9]|1[0-2])$' then return jsonb_build_object('ok', false, 'error', 'p_ymはYYYY-MM'); end if;
  v_from := (v_ym || '-01')::date; v_to := (v_from + interval '1 month')::date;
  v_due := v_to + 4;                                    -- 翌月5日
  v_key := 'expense-monthly:' || v_ym;
  v_title := (substr(v_ym, 6, 2)::int)::text || '月分従業員経費';
  select id into v_assignee from public.users where replace(replace(name, '　', ''), ' ', '') = '原美香' and is_active limit 1;
  select count(*) into v_cnt from public.expense_requests e where e.status = 'approved' and e.payment_type = 'tatekae' and (e.decided_at at time zone 'Asia/Tokyo')::date >= v_from and (e.decided_at at time zone 'Asia/Tokyo')::date < v_to;
  select count(*) into v_pending from public.expense_requests e where e.status = 'pending' and (e.applied_at at time zone 'Asia/Tokyo')::date >= v_from and (e.applied_at at time zone 'Asia/Tokyo')::date < v_to;
  if v_cnt = 0 then return jsonb_build_object('ok', true, 'created', false, 'reason', '承認済みの立替経費がありません', 'pending', v_pending); end if;

  select id into v_task from public.hq_tasks where exception_key = v_key and deleted_at is null limit 1;
  if v_task is null then
    insert into public.hq_tasks (title, corp, freq, target_date, due_date, status, visibility, notes, memo, exception_key, is_urgent)
    values (v_title, 'N-Style', 'monthly', (v_to - 1), v_due, 'todo', 'all',
            '承認済みの立替経費（承認日が' || v_ym || '）を従業員ごとに合計。承認待ちは含みません（承認されると工程の金額が更新されます）。',
            '従業員経費の月次集計（自動作成）', v_key, false) returning id into v_task;
    insert into public.hq_task_activity (task_id, actor_id, kind, detail) values (v_task, null, 'create', '月末の従業員経費の集計として自動作成');
  end if;
  for rec in
    select e.applicant_id, u.name, sum(e.amount) total, count(*) n from public.expense_requests e join public.users u on u.id = e.applicant_id
    where replace(replace(u.name, '　', ''), ' ', '') <> '佐藤俊一' and e.status = 'approved' and e.payment_type = 'tatekae' and (e.decided_at at time zone 'Asia/Tokyo')::date >= v_from and (e.decided_at at time zone 'Asia/Tokyo')::date < v_to group by e.applicant_id, u.name order by u.name
  loop
    i := i + 1;
    v_title2 := rec.name || '　' || to_char(rec.total, 'FM999,999,999') || '円（' || rec.n || '件）';
    if exists (select 1 from public.hq_task_steps s where s.task_id = v_task and s.procedure_note = 'expense_user:' || rec.applicant_id::text and s.title = v_title2) then
      null;   -- 変化なし
    elsif exists (select 1 from public.hq_task_steps s where s.task_id = v_task and s.procedure_note = 'expense_user:' || rec.applicant_id::text and s.completed_at is not null) then
      null;   -- 完了済みの工程は触らない
    else
      -- 金額が変わった未完了の工程は作り直す（工程の直接編集は画面権限のトリガーで止まるため、削除→追加にしている）
      if exists (select 1 from public.hq_task_steps s where s.task_id = v_task and s.procedure_note = 'expense_user:' || rec.applicant_id::text) then
        delete from public.hq_task_steps s where s.task_id = v_task and s.procedure_note = 'expense_user:' || rec.applicant_id::text and s.completed_at is null;
        n_upd := n_upd + 1;
      else
        n_new := n_new + 1;
      end if;
      insert into public.hq_task_steps (task_id, title, assignee_id, assignee_ids, due_date, sort_order, kind, is_binary, requires_photo, procedure_note)
        values (v_task, v_title2, v_assignee, case when v_assignee is null then null else array[v_assignee] end,
                v_due, i * 10, 'step', false, false, 'expense_user:' || rec.applicant_id::text);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'task_id', v_task, 'title', v_title, 'due', v_due, 'assignee', v_assignee, 'steps_new', n_new, 'steps_updated', n_upd, 'pending_excluded', v_pending);
end $$;
revoke all on function public.hq_expense_monthly_task(text) from public, anon;
grant execute on function public.hq_expense_monthly_task(text) to authenticated, service_role;
