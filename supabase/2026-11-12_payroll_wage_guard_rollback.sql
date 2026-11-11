-- 2026-11-12_payroll_wage_guard.sql を外す  ★実行は別途承認
--   先に: スイッチ payroll_wage_guard を false に戻すこと（true のままだと止まる）。
--   例外解除の申請と履歴・照合の記録は消える（先に控えを取ること）。振込の除外の記録（payroll_transfer_holds）は残る（理由の列だけ消える）。
do $$
begin
  if coalesce((select (value ->> 'payroll_wage_guard')::boolean from app_settings where key = 'employee_change'), false) then raise exception 'スイッチ payroll_wage_guard が true です。先に false に戻してください'; end if;
  if exists (select 1 from information_schema.columns where table_name = 'payroll_transfer_holds' and column_name = 'reasons')
     and exists (select 1 from payroll_transfer_holds where status in ('held', 'ready') and 'wage_unapproved' = any(reasons)) then
    raise exception '未承認の賃金変更が理由で振込データから外したままの人がいます。先に処理してください';
  end if;
end $$;
drop trigger if exists payroll_finalized_wage_guard on payroll_finalized;
drop trigger if exists payroll_transfer_schedule_wage_guard on payroll_transfer_schedule;
drop trigger if exists cash_handoff_wage_guard on sf_cash_handoff_signatures;
-- 既存の振込の関数を、足す前の定義に戻す
CREATE OR REPLACE FUNCTION public.pay_transfer_pending_holds(p_year_month text)
 RETURNS TABLE(user_id uuid, request_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select q.user_id, q.id from profile_change_requests q
   where q.field = 'bank_account' and q.status = 'pending' and (q.effective_year_month is null or q.effective_year_month <= p_year_month)
     -- いま銀行振込の口座が登録されている人だけ（口座が未登録・現金手渡しの人は、もともと振込データに入らない＝従来どおりの扱い）
     and exists (select 1 from payroll_bank_accounts b where b.user_id = q.user_id and coalesce(b.payment_method, 'bank_transfer') <> 'cash')
     and not exists (select 1 from payroll_transfer_schedule t where t.year_month = p_year_month
                      and t.created_at < coalesce((select (value ->> 'transfer_guard_since')::timestamptz from app_settings where key = 'employee_change'), '-infinity'::timestamptz))
     and not exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = p_year_month and s.user_id = q.user_id)
$function$;

CREATE OR REPLACE FUNCTION public.payroll_transfer_schedule_after()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_new int := 0; v_on boolean; v_holds uuid[];
begin
  if coalesce(current_setting('employee_change.schedule_internal', true), '') <> '' then return null; end if;   -- 【要確認】タスクの印を付けるだけの内部の更新
  begin
    if new.invalid_export_at is not null and (tg_op = 'INSERT' or new.invalid_export_at is distinct from old.invalid_export_at) then
      -- ⑥ 印の無い出力: 確定として扱わない（控え・除外の処理をしない）。本部に知らせる
      perform pay_transfer_invalid_export_task(new.year_month);
      return null;
    end if;
    if new.export_ok is not true then return null; end if;
    if exists (select 1 from payroll_transfer_export_tokens t where t.token = new.export_token and t.used_at is not null) then return null; end if;   -- 同じ印では 1 回だけ処理する
    update payroll_transfer_export_tokens set used_at = now() where token = new.export_token;
    -- ① 画面に「除外する」と伝えた人（出力の印に控えてある）を、除外として記録。その後に申請が片付いていれば「その人の分が未出力」から始める
    select t.hold_users into v_holds from payroll_transfer_export_tokens t where t.token = new.export_token;
    with ins as (
      insert into payroll_transfer_holds(year_month, user_id, request_id, status, resolved_at)
      select new.year_month, u.id,
             (select q.id from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' order by (q.status = 'pending') desc, q.requested_at desc limit 1),
             case when exists (select 1 from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' and q.status = 'pending') then 'held' else 'ready' end,
             case when exists (select 1 from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' and q.status = 'pending') then null else now() end
        from unnest(coalesce(v_holds, '{}')) as u(id)
       where not exists (select 1 from payroll_transfer_account_snapshots sn where sn.year_month = new.year_month and sn.user_id = u.id)
      on conflict (year_month, user_id) do update set request_id = excluded.request_id, status = excluded.status, resolved_at = excluded.resolved_at where payroll_transfer_holds.status <> excluded.status and payroll_transfer_holds.status <> 'done'
      returning 1)
    select count(*) into v_new from ins;
    -- ② それ以外の人の口座の控え（最初の出力時点のもの。出し直しても自動では変えない。出力後に口座を登録した人・除外が解けた人だけ足される）
    insert into payroll_transfer_account_snapshots(year_month, user_id, account, taken_by)
    select new.year_month, b.user_id, to_jsonb(b) - 'created_at' - 'updated_at' - 'updated_by' - 'user_id', auth.uid() from payroll_bank_accounts b
     where not (b.user_id = any(coalesce(v_holds, '{}')))
    on conflict (year_month, user_id) do nothing;
    -- ③ 除外が解けていた人（ready）は、今回の出力で振込データに入った＝完了
    update payroll_transfer_holds h set status = 'done', done_at = now() where h.year_month = new.year_month and h.status = 'ready' and not (h.user_id = any(coalesce(v_holds, '{}')))
       and exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = h.year_month and s.user_id = h.user_id);
    perform pay_transfer_hold_task_sync(new.year_month);
    if v_new > 0 then
      select coalesce((value ->> 'pay_request_notify_enabled')::boolean, false) into v_on from app_settings where key = 'employee_change';
      if coalesce(v_on, false) then perform pay_change_notify_op('transfer_hold', jsonb_build_object('year_month', new.year_month)); end if;
    end if;
    perform hr_apply_due_bank_changes_internal();   -- この回の出力が済んだので、次の回からの予約を反映
  exception when others then perform employee_change_log_error('payroll_transfer_schedule', lower(tg_op), null, sqlerrm);
  end;
  return null;
end $function$;

CREATE OR REPLACE FUNCTION public.pay_transfer_hold_task_sync(p_year_month text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_task uuid; v_step uuid; h record; v_item uuid; v_assignee uuid; v_open int; v_cstep uuid; v_title text;
begin
  -- 既存の「給与振込確認」タスク（出力のたびに作られる／更新される）。除外した人を「未振込」として載せる
  select st.id into v_cstep from transfer_confirm_task_links l join hq_tasks k on k.id = l.hq_task_id join hq_task_steps st on st.task_id = k.id
   where l.kind = 'payroll' and l.scope_key = p_year_month and k.deleted_at is null order by st.sort_order limit 1;
  for h in select * from payroll_transfer_holds where year_month = p_year_month loop
    v_title := '⚠️ 未振込: ' || coalesce((select name from users where id = h.user_id), '—') || 'さん（口座変更の承認待ちで除外）';
    if v_cstep is not null then
      if h.status in ('held', 'ready') and not exists (select 1 from hq_step_checklist_items c where c.step_id = v_cstep and c.title = v_title) then
        insert into hq_step_checklist_items(step_id, title, sort_order) values (v_cstep, v_title, 5);
      elsif h.status = 'done' then
        update hq_step_checklist_items set checked_at = now(), checked_by = auth.uid() where step_id = v_cstep and title = v_title and checked_at is null;
      end if;
    end if;
  end loop;
  select hq_task_id into v_task from payroll_transfer_holds where year_month = p_year_month and hq_task_id is not null limit 1;
  if v_task is null then
    if not exists (select 1 from payroll_transfer_holds where year_month = p_year_month and status in ('held', 'ready')) then return null; end if;
    select u.id into v_assignee from users u where u.name in ('青山純', '原　美香', '齋藤　隆治') and u.is_active order by array_position(array['青山純', '原　美香', '齋藤　隆治'], u.name) limit 1;
    insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by, is_urgent)
    values ('【振込漏れ注意】' || p_year_month || ' 月分の給与振込: 口座変更の確認待ちで除外した人がいます', 'トーホー', 'once', current_date, least(pay_run_date(p_year_month), current_date + 3), '',
            p_year_month || ' 月分（' || pay_run_date(p_year_month) || ' 支給）の振込データから、口座変更の申請が承認待ちの人を除外しました。このままでは、その人に振り込まれません。'
            || E'\n' || '① 従業員ページで口座変更の申請を承認（どの支給回からかを選ぶ）または却下する ② 振込画面で「除外していた人の分を出力」して振り込む。'
            || E'\n' || '②まで終わると、このタスクのチェックは自動で付きます。口座番号などはここには表示しません。', 'all', auth.uid(), true)
    returning id into v_task;
    insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date) values (v_task, '除外した人の申請を処理し、その人の分の振込データを出力する', v_assignee, 10, 'step', least(pay_run_date(p_year_month), current_date + 3)) returning id into v_step;
    insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, auth.uid(), 'create', '振込データの出力で除外した人がいるため自動作成');
  else
    select id into v_step from hq_task_steps where task_id = v_task order by sort_order limit 1;
  end if;
  for h in select * from payroll_transfer_holds where year_month = p_year_month loop
    if h.checklist_item_id is null then
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_step, coalesce((select name from users where id = h.user_id), '—') || 'さん', 10) returning id into v_item;
      update payroll_transfer_holds set hq_task_id = v_task, checklist_item_id = v_item where year_month = h.year_month and user_id = h.user_id;
      h.checklist_item_id := v_item;
    end if;
    if h.status = 'done' then update hq_step_checklist_items set checked_at = coalesce(checked_at, now()), checked_by = coalesce(checked_by, auth.uid()) where id = h.checklist_item_id; end if;
  end loop;
  select count(*) into v_open from payroll_transfer_holds where year_month = p_year_month and status in ('held', 'ready');
  if v_open = 0 then update hq_task_steps set completed_at = now(), completed_by = auth.uid() where task_id = v_task and completed_at is null; end if;
  return v_task;
end $function$;

CREATE OR REPLACE FUNCTION public.hr_payroll_transfer_prepare(p_year_month text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_applied integer := 0; v_snap jsonb; v_token uuid; v_hold uuid[];
begin
  if not (invoice_can_access() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  if p_year_month !~ '^\d{4}-\d{2}$' then raise exception '月（YYYY-MM）が不正です'; end if;
  if pay_transfer_paused() then   -- ⑤ 切り替え作業中: 何もしないで「停止中」だけ返す
    return jsonb_build_object('ok', true, 'paused', true, 'year_month', p_year_month, 'attention', '[]'::jsonb, 'hold', '[]'::jsonb, 'ready', '[]'::jsonb, 'hold_records', '[]'::jsonb);
  end if;
  begin v_applied := hr_apply_due_bank_changes_internal();
  exception when others then perform employee_change_log_error('payroll_transfer_prepare', 'apply_due', null, sqlerrm); end;
  -- 口座の控えは、登録口座を読める人（マスター・本部）にだけ返す
  if (is_profile_approver() or onboarding_is_service()) and exists (select 1 from payroll_transfer_schedule where year_month = p_year_month and export_ok is not false) then
    select jsonb_object_agg(s.user_id, s.account || jsonb_build_object('user_id', s.user_id, '_source', s.source)) into v_snap from payroll_transfer_account_snapshots s where s.year_month = p_year_month;
  end if;
  -- ⑥ 出力の印を発行（この呼び出しのあとの出力 1 回ぶん。除外するよう伝えた人を控える）
  select coalesce(array_agg(h.user_id), '{}') into v_hold from pay_transfer_pending_holds(p_year_month) h;
  if auth.uid() is not null then
    delete from payroll_transfer_export_tokens where issued_at < now() - interval '2 days';
    insert into payroll_transfer_export_tokens(year_month, user_id, hold_users) values (p_year_month, auth.uid(), v_hold) returning token into v_token;
  end if;
  return jsonb_build_object('ok', true, 'paused', false, 'export_token', v_token, 'year_month', p_year_month, 'state', pay_run_state(p_year_month), 'pay_date', pay_run_date(p_year_month), 'applied', v_applied,
    'snapshot', v_snap, 'attention', hr_pay_change_attention_internal(p_year_month),
    -- hold=この回の振込データに入れてはいけない人（未承認の口座変更が影響）／ready=除外していたが申請が片付いた人（その人の分を出す）
    'hold', (select coalesce(jsonb_agg(jsonb_build_object('user_id', h.user_id, 'user_name', (select name from users u where u.id = h.user_id), 'request_id', h.request_id)), '[]'::jsonb) from pay_transfer_pending_holds(p_year_month) h),
    'ready', (select coalesce(jsonb_agg(jsonb_build_object('user_id', h.user_id, 'user_name', (select name from users u where u.id = h.user_id))), '[]'::jsonb) from payroll_transfer_holds h where h.year_month = p_year_month and h.status = 'ready'),
    'transfer_pending_mode', coalesce((select value ->> 'transfer_pending_mode' from app_settings where key = 'employee_change'), 'exclude'),
    -- 除外の記録（誰が・なぜ・いまの状況）。振込が済んだもの（done）も履歴として返す
    'hold_records', (select coalesce(jsonb_agg(jsonb_build_object('user_id', h.user_id, 'user_name', (select name from users u where u.id = h.user_id), 'status', h.status,
                       'reason', '口座変更の申請が承認待ちだったため（振込先が確定していない）',
                       'status_label', case h.status when 'held' then '除外中（申請の承認・却下が必要）' when 'ready' then '申請は処理済み・この人の分の振込データが未出力' else '振込データ出力済み' end,
                       'request_status', (select q.status from profile_change_requests q where q.id = h.request_id), 'excluded_at', h.created_at, 'resolved_at', h.resolved_at, 'done_at', h.done_at) order by h.created_at), '[]'::jsonb)
                      from payroll_transfer_holds h where h.year_month = p_year_month),
    'bank_approval_required', coalesce((select (value ->> 'bank_approval_required')::boolean from app_settings where key = 'employee_change'), false));
end $function$;

CREATE OR REPLACE FUNCTION public.hr_pay_change_attention_internal(p_year_month text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'field', x.field, 'request_id', x.id, 'user_id', x.user_id, 'user_name', x.user_name, 'message', x.message) order by x.ord, x.requested_at), '[]'::jsonb)
  from (
    select q.id, q.field, q.user_id, q.requested_at, (select name from users u where u.id = q.user_id) user_name,
      case when q.apply_status in ('blocked_exported', 'blocked_finalized') then 'conflict'
           when q.status = 'pending' then 'unapproved' else 'sync_error' end kind,
      case when q.apply_status in ('blocked_exported', 'blocked_finalized') then 1 when q.status = 'pending' then 2 else 3 end ord,
      case when q.apply_status = 'blocked_exported' then '口座変更が未反映です（決めた支給回は振込データ出力済み）。支給回を選び直すか、個別の確認・承認をしてください'
           when q.apply_status = 'blocked_finalized' then '賃金変更が未反映です（適用開始月の給与が確定済み）'
           when q.status = 'pending' and q.field = 'bank_account' then '口座変更の申請が承認待ちです（承認されるまで今の口座のまま振り込みます）'
           when q.status = 'pending' then '賃金変更の申請が承認待ちです（適用開始日 ' || coalesce(q.effective_date::text, '—') || '）'
           else 'スマレジへの賃金の同期がエラーです（賃金カードから再実行してください）' end message
    from profile_change_requests q
    where q.field in ('wage', 'bank_account') and (
         (q.status = 'approved' and q.apply_status in ('blocked_exported', 'blocked_finalized'))
      or (q.status = 'pending' and (q.field = 'bank_account' or p_year_month is null or q.effective_date <= (to_date(p_year_month || '-01', 'YYYY-MM-DD') + interval '1 month' - interval '1 day')::date))
      or (q.status = 'approved' and q.field = 'wage' and q.apply_status = 'applied' and exists (select 1 from employee_wage_settings w where w.id = nullif(q.apply_ref ->> 'wage_setting_id', '')::uuid and w.sync_status = 'error')))
    union all
    -- 振込データから除外した人（振込漏れ防止）: 除外中／申請は片付いたが、その人の分の振込データがまだ
    select h.request_id, 'bank_account', h.user_id, h.created_at, (select name from users u where u.id = h.user_id), 'transfer_hold', 0,
      case when h.status = 'held' then h.year_month || ' 月分の振込データから除外中です（口座変更の申請が承認待ち）。このままでは振り込まれません'
           else h.year_month || ' 月分の振込データが未出力です（口座変更の申請は処理済み）。振込画面で「除外していた人の分を出力」してください' end
      || case when pay_run_state(h.year_month) = 'paid' then '【支給日（' || pay_run_date(h.year_month) || '）を過ぎています】' else '' end
    from payroll_transfer_holds h where h.status in ('held', 'ready')   -- 振込が済む（done）まで、支給日を過ぎても出し続ける
    union all
    -- 古い画面・直接の API からの出力（【要確認】のタスクを完了にするまで出し続ける）
    select null::uuid, 'bank_account', null::uuid, sc.invalid_export_at, '振込画面', 'invalid_export', 0,
      sc.year_month || ' 月分の振込 CSV が古い画面から出力されました。そのファイルは使わず、画面を再読み込みして出力し直してください（本部タスク【要確認】を確認）'
    from payroll_transfer_schedule sc where sc.invalid_export_at is not null and exists (select 1 from hq_tasks k where k.id = sc.invalid_task_id and k.status <> 'done' and k.deleted_at is null)
  ) x
$function$;

CREATE OR REPLACE FUNCTION public.payroll_transfer_confirm_step_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ym text; v_names text;
begin
  if not (new.completed_at is not null and old.completed_at is null) then return new; end if;
  begin
    select l.scope_key into v_ym from transfer_confirm_task_links l where l.kind = 'payroll' and l.hq_task_id = new.task_id limit 1;
    if v_ym is not null then
      select string_agg((select name from users u where u.id = h.user_id) || 'さん', '、') into v_names from payroll_transfer_holds h where h.year_month = v_ym and h.status in ('held', 'ready');
    end if;
  exception when others then v_names := null;   -- 判定そのものの失敗では、本部タスクの操作を止めない
  end;
  if v_names is not null then
    raise exception '% 月分の給与振込は、まだ完了にできません。口座変更の承認待ちで振込データから除外した人の振込が済んでいません（%）。申請を承認または却下し、振込画面で「除外していた人の分を出力」して振り込んでから完了にしてください', v_ym, v_names;
  end if;
  return new;
end $function$;

drop function if exists payroll_finalized_wage_guard();
drop function if exists payroll_transfer_schedule_wage_guard();
drop function if exists cash_handoff_wage_guard();
drop function if exists cash_handoff_wage_holds(text);
drop function if exists hr_payroll_wage_guard_status(text, uuid);
drop function if exists hr_payroll_wage_hold_release_request(text, uuid, uuid, text, uuid);
drop function if exists hr_payroll_wage_hold_release_decide(uuid, text, text, uuid);
drop function if exists hr_payroll_wage_hold_release_cancel(uuid, text, uuid);
drop function if exists pay_transfer_holds_wage_fix(text, uuid[]);
drop function if exists pay_transfer_holds_wage_refresh(text);
drop function if exists pay_transfer_hold_reason_label(text[]);
drop function if exists pay_transfer_hold_reason_text(text[]);
drop function if exists payroll_wage_guard_summary(text);
drop function if exists payroll_wage_stop_text(jsonb);
drop function if exists payroll_wage_stop(text);
drop function if exists payroll_wage_holds(text);
drop function if exists payroll_wage_guard_i(text, uuid);
drop function if exists payroll_wage_guard_label(text);
drop function if exists payroll_wage_guard_enabled();
drop function if exists hr_wage_reconcile_log(text, integer, integer, integer, integer, uuid[], integer, boolean, boolean, text);
drop table if exists payroll_wage_hold_release_log;
drop function if exists payroll_wage_hold_release_log_guard();
drop table if exists payroll_wage_hold_releases;
drop table if exists wage_reconcile_runs;
alter table payroll_transfer_holds drop column if exists reasons;
update app_settings set value = value - 'payroll_wage_guard' - 'wage_guard_max_age_hours' - 'wage_guard_unread_ratio' where key = 'employee_change';
