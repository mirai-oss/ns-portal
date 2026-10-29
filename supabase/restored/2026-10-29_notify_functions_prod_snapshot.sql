-- =============================================================
-- 通知関連 DB 関数の本番スナップショット（2026-10-29・pg_get_functiondef で取得・無改変）
-- 目的: Slack移行（docs/設計書_Slack通知基盤_Phase1_2026-10-29.md）で notify_route_send 等を
--       変更する前に、本番の現行定義をリポジトリに残す（これまで未管理だった）。
-- 注意: これは「復元した記録」であり、マイグレーションとして適用するファイルではない。
--       変更は日付入りの新規SQLファイルで行う（既存ファイルは編集しない鉄則どおり）。
--       notify_route_send 内の sb_publishable_… は公開用（anon/publishable）キーで秘密ではない。
-- 対象関数（22）: apply_submit, cash_handoff_complete, expense_approve, expense_reject, expense_submit, hq_check_alerts, hq_check_payroll_task_item, hq_notify_comment, hq_notify_step_event, hq_notify_task_urgent, hq_personal_chatwork_room, hq_personal_chatwork_room_for_event, lark_route_test, lark_test, notify_join_complete, notify_join_resend, notify_lark, notify_lark_url, notify_report_lark, notify_route_send, resolve_store, trg_lark_notify
-- =============================================================

-- ---------- apply_submit ----------
CREATE OR REPLACE FUNCTION public.apply_submit(p_form_key text, p_name text, p_phone text DEFAULT NULL::text, p_email text DEFAULT NULL::text, p_answers jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid; f applicant_forms%rowtype; v_dup boolean := false;
  v_prefs jsonb; v_ptxt text; v_ans jsonb;
begin
  select * into f from applicant_forms where key = p_form_key and is_active;
  if not found then raise exception 'フォームが見つかりません'; end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception '氏名を入力してください'; end if;
  if length(coalesce(p_name,'')) > 100 or length(coalesce(p_phone,'')) > 50
     or length(coalesce(p_email,'')) > 200 or pg_column_size(p_answers) > 100000 then
    raise exception '入力が長すぎます';
  end if;

  v_ans   := coalesce(p_answers,'{}'::jsonb);
  v_prefs := v_ans -> '_面接希望';                 -- v2.6.35 希望日時を取り出す
  if jsonb_typeof(v_prefs) is distinct from 'array' then v_prefs := null; end if;
  v_ptxt  := interview_prefs_text(v_prefs);
  -- 応募者カードで読めるように、日本語の1行も回答に残す
  if v_ptxt is not null then
    v_ans := v_ans || jsonb_build_object('面接の希望日時', v_ptxt);
  end if;

  -- v2.6.30 すでに同じ人がいれば、その人に足す（新しく作らない）
  v_id := applicant_match(p_name, p_phone, p_email);
  if v_id is not null then
    v_dup := true;
    update applicants set
      answers  = answers || v_ans,
      form_key = coalesce(form_key, p_form_key),
      phone    = coalesce(nullif(btrim(coalesce(phone,'')),''), nullif(btrim(coalesce(p_phone,'')),'')),
      email    = coalesce(nullif(btrim(coalesce(email,'')),''), nullif(btrim(coalesce(p_email,'')),'')),
      interview_prefs = coalesce(v_prefs, interview_prefs),
      form_received_at = now(),
      form_seen_at = null,
      updated_at = now()
     where id = v_id;
  else
    v_id := gen_random_uuid();
    insert into applicants (id, form_key, name, phone, email, source, answers, interview_prefs)
    values (v_id, p_form_key, trim(p_name),
            nullif(trim(coalesce(p_phone,'')),''), nullif(trim(coalesce(p_email,'')),''),
            'form', v_ans, v_prefs);
  end if;

  -- 採用担当へ通知（Lark・Chatworkにもこの本文がそのまま飛ぶ）
  insert into notifications (recipient_id, type, body_i18n, link)
  select u.id, 'applicant_new',
         jsonb_build_object('ja',
           case when v_dup then 'すでに登録がある方から応募がありました: '
                           else '新しい応募がありました: ' end
           || trim(p_name) || 'さん（' || f.title || '）'
           || case when v_ptxt is not null then E'\n面接の希望日時: ' || v_ptxt else '' end
           || case when coalesce(btrim(p_phone),'') <> '' then E'\n電話: ' || btrim(p_phone) else '' end),
         jsonb_build_object('applicant_id', v_id)
    from users u where u.is_active and has_feature(u.id, 'recruit');
  return v_id;
end $function$
;

-- ---------- cash_handoff_complete ----------
CREATE OR REPLACE FUNCTION public.cash_handoff_complete(p_user_id uuid, p_year_month text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_row sf_cash_handoff_signatures%rowtype;
  v_synced_rows integer := 0;
  v_already_done boolean;
  v_uname text;
  v_total int; v_done int;
begin
  if not exists(select 1 from users where id = auth.uid() and is_active and (
    is_master or role in ('CEO','HQ','TENCHO','TEAM')
  )) then
    raise exception '権限がありません';
  end if;
  select * into v_row from sf_cash_handoff_signatures where user_id = p_user_id and year_month = p_year_month;
  if v_row.id is null then
    raise exception '対象の記録が見つかりません';
  end if;
  if v_row.payer_checked_at is null or v_row.receiver_checked_at is null then
    raise exception '渡した側・受け取った側、両方の確認が必要です';
  end if;

  v_already_done := v_row.completed_at is not null;
  update sf_cash_handoff_signatures set completed_at = coalesce(completed_at, now()), updated_at = now()
   where id = v_row.id;

  begin
    update payroll_journal_records set paid_at = now(), paid_by = auth.uid()
     where user_id = p_user_id and year_month = p_year_month and paid_at is null;
    get diagnostics v_synced_rows = row_count;
  exception when undefined_table then v_synced_rows := 0;
  end;

  if not v_already_done then
    -- 2026-09-08追加: 本部タスク（現金手渡し）のチェックリストを自動で連携
    begin
      select name into v_uname from users where id = p_user_id;
      if v_uname is not null then
        perform hq_check_payroll_task_item(p_year_month, 'cash', v_uname);
      end if;
    exception when others then null; -- 本部タスク未発行等でも現金手渡し自体の完了は止めない
    end;

    -- その月の現金手渡し対象者が全員完了したらLarkへ報告
    begin
      select count(*) into v_total
        from payroll_bank_accounts pba join users u on u.id = pba.user_id
        where pba.payment_method = 'cash' and u.is_active;
      select count(*) into v_done
        from sf_cash_handoff_signatures s
        join payroll_bank_accounts pba on pba.user_id = s.user_id and pba.payment_method = 'cash'
        join users u on u.id = s.user_id and u.is_active
        where s.year_month = p_year_month and s.completed_at is not null;
      if v_total > 0 and v_total = v_done then
        perform notify_lark('💴 現金手渡し完了：'||p_year_month||'分の現金手渡し対象者 全'||v_total||'名の受け渡しが完了しました（nippo「現金手渡し・サイン」）');
      end if;
    exception when others then null;
    end;
  end if;

  return jsonb_build_object('ok', true, 'journal_marked_paid', v_synced_rows > 0);
end;
$function$
;

-- ---------- expense_approve ----------
CREATE OR REPLACE FUNCTION public.expense_approve(p_request_id uuid, p_comment text DEFAULT NULL::text)
 RETURNS TABLE(channel_kind text, target text, keyword text, title text, body text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_req record; v_tpl_id uuid; v_task_id uuid;
  v_step record; v_store record;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_personal text; v_title text; v_body text; v_applicant_name text; v_today date := current_date;
begin
  select * into v_req from expense_requests where id = p_request_id;
  if v_req is null then raise exception '申請が見つかりません'; end if;
  if v_req.status <> 'pending' then raise exception 'この申請は承認待ちではありません'; end if;
  if v_req.approver_id <> auth.uid() and not expense_can_manage() then
    raise exception 'この申請の承認者ではありません';
  end if;

  insert into expense_approvals(request_id, step_no, approver_id, action, comment)
  values (p_request_id, 1, auth.uid(), 'approved', p_comment);

  v_tpl_id := coalesce(v_req.task_template_id, (select value::uuid from expense_settings where key = 'default_task_template_id'));
  select name into v_applicant_name from users where id = v_req.applicant_id;

  insert into hq_tasks (template_id, title, corp, freq, target_date, due_date, due_time, notes, description, visibility, memo, created_by)
  select t.id, t.title, t.corp, t.freq, v_today, v_today + t.due_offset_days, t.due_time,
         t.notes, t.description, t.visibility,
         '経費申請 #' || substr(p_request_id::text,1,8) || ' ／ ' || coalesce(v_applicant_name,'') || ' ／ ' || v_req.amount::text || '円 ／ ' || v_req.purpose,
         auth.uid()
  from hq_task_templates t
  where t.id = v_tpl_id
  on conflict (template_id, target_date) do nothing
  returning id into v_task_id;

  if v_task_id is not null then
    for v_step in select * from hq_task_template_steps where template_id = v_tpl_id order by sort_order loop
      if v_step.kind = 'check' and v_step.store_scope is not null then
        for v_store in
          select id from stores where
            case when v_step.store_ids is not null and array_length(v_step.store_ids,1) > 0 then id = any(v_step.store_ids)
                 else (v_step.store_scope = 'all' or is_active) end
          order by sort_order
        loop
          insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo, store_id)
          values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_today + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo, v_store.id);
        end loop;
      else
        insert into hq_task_steps(task_id, template_step_id, title, assignee_id, due_date, due_time, sort_order, kind, is_binary, requires_photo)
        values (v_task_id, v_step.id, v_step.title, v_step.assignee_id, v_today + v_step.offset_days, v_step.due_time, v_step.sort_order, v_step.kind, v_step.is_binary, v_step.requires_photo);
      end if;
    end loop;
    insert into hq_task_activity(task_id, actor_id, kind, detail)
    values (v_task_id, auth.uid(), 'create', '経費申請の承認により自動生成');
  end if;

  update expense_requests set
    status = 'approved', decided_at = now(), updated_at = now(),
    created_task_id = coalesce(v_task_id, created_task_id)
  where id = p_request_id;

  v_title := '経費申請が承認されました';
  v_body := v_req.purpose || '（' || v_req.amount::text || '円）';
  insert into hq_notifications(recipient_id, kind, title, body) values (v_req.applicant_id, 'due_alert', v_title, v_body);
  v_personal := hq_personal_chatwork_room(v_req.applicant_id);
  if v_personal is not null then
    v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text;
    v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
  end if;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$function$
;

-- ---------- expense_reject ----------
CREATE OR REPLACE FUNCTION public.expense_reject(p_request_id uuid, p_reason text)
 RETURNS TABLE(channel_kind text, target text, keyword text, title text, body text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_req record;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_personal text; v_title text; v_body text;
begin
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception '差戻し理由を入力してください';
  end if;
  select * into v_req from expense_requests where id = p_request_id;
  if v_req is null then raise exception '申請が見つかりません'; end if;
  if v_req.status <> 'pending' then raise exception 'この申請は承認待ちではありません'; end if;
  if v_req.approver_id <> auth.uid() and not expense_can_manage() then
    raise exception 'この申請の承認者ではありません';
  end if;

  insert into expense_approvals(request_id, step_no, approver_id, action, comment)
  values (p_request_id, 1, auth.uid(), 'rejected', p_reason);

  update expense_requests set
    status = 'rejected', reject_reason = p_reason, decided_at = now(), updated_at = now()
  where id = p_request_id;

  v_title := '経費申請が差し戻されました';
  v_body := v_req.purpose || '（' || v_req.amount::text || '円） — 理由: ' || p_reason;
  insert into hq_notifications(recipient_id, kind, title, body) values (v_req.applicant_id, 'issue_reported', v_title, v_body);
  v_personal := hq_personal_chatwork_room(v_req.applicant_id);
  if v_personal is not null then
    v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text;
    v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
  end if;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$function$
;

-- ---------- expense_submit ----------
CREATE OR REPLACE FUNCTION public.expense_submit(p_request_id uuid)
 RETURNS TABLE(channel_kind text, target text, keyword text, title text, body text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_req record; v_approver uuid; v_flow uuid;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_personal text; v_title text; v_body text; v_applicant_name text;
begin
  select * into v_req from expense_requests where id = p_request_id;
  if v_req is null then raise exception '申請が見つかりません'; end if;
  if v_req.applicant_id <> auth.uid() then raise exception '自分の申請だけ提出できます'; end if;
  if v_req.status <> 'draft' then raise exception 'この申請はすでに提出済みです'; end if;

  v_approver := expense_default_approver(v_req.applicant_id);
  if v_approver is null then
    raise exception '承認者を自動設定できませんでした。本部に承認ルート設定の確認を依頼してください';
  end if;
  select id into v_flow from expense_flows where is_default limit 1;

  update expense_requests set
    status = 'pending', approver_id = v_approver, flow_id = v_flow,
    applied_at = now(), updated_at = now()
  where id = p_request_id;

  select name into v_applicant_name from users where id = v_req.applicant_id;
  v_title := '経費申請の承認をお願いします';
  v_body := coalesce(v_applicant_name,'') || 'さん — ' || v_req.purpose || '（' || v_req.amount::text || '円）';
  insert into hq_notifications(recipient_id, kind, title, body) values (v_approver, 'due_alert', v_title, v_body);

  v_personal := hq_personal_chatwork_room(v_approver);
  if v_personal is not null then
    v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text;
    v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
  end if;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$function$
;

-- ---------- hq_check_alerts ----------
CREATE OR REPLACE FUNCTION public.hq_check_alerts()
 RETURNS TABLE(channel_kind text, target text, keyword text, title text, body text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_today date := current_date;
  v_task record;
  v_cur record;
  v_alert record;
  v_recipients uuid[];
  v_r uuid;
  v_event text;
  v_title text;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_ch record;
  v_personal text;
  v_stalled_days int;
  v_since timestamptz;
  v_url text;
begin
  for v_task in select t.* from hq_tasks t where t.status <> 'done' loop
    v_url := 'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || v_task.id;
    select s.* into v_cur from hq_task_steps s where s.task_id=v_task.id and s.completed_at is null order by s.sort_order limit 1;
    if v_cur is null then continue; end if;

    select * into v_alert from hq_task_alerts where task_id = v_task.id;
    v_event := null; v_title := null;
    v_recipients := coalesce(v_cur.assignee_ids, case when v_cur.assignee_id is not null then array[v_cur.assignee_id] else null end, array[v_task.created_by]);

    if v_cur.due_date is not null then
      if v_cur.due_date < v_today and coalesce(v_alert.overdue_daily, (select alert_overdue_daily from hq_task_templates where id=v_task.template_id), true) then
        v_event := 'due_alert'; v_title := '期限超過: ' || v_task.title;
      elsif v_cur.due_date = v_today and coalesce(v_alert.due, (select alert_due from hq_task_templates where id=v_task.template_id), true) then
        v_event := 'due_alert'; v_title := '本日期限: ' || v_task.title;
      elsif v_cur.due_date = v_today + 1 and coalesce(v_alert.before1, (select alert_before1 from hq_task_templates where id=v_task.template_id), true) then
        v_event := 'due_alert'; v_title := '明日期限: ' || v_task.title;
      elsif v_cur.due_date = v_today + 3 and coalesce(v_alert.before3, (select alert_before3 from hq_task_templates where id=v_task.template_id), true) then
        v_event := 'due_alert'; v_title := '期限3日前: ' || v_task.title;
      end if;
    end if;

    if v_event is not null and not exists(
      select 1 from hq_notifications n where n.task_id=v_task.id and n.kind='due_alert' and n.created_at::date = v_today
    ) then
      foreach v_r in array v_recipients loop
        if v_r is not null then
          insert into hq_notifications(recipient_id, task_id, kind, title, body) values (v_r, v_task.id, 'due_alert', v_title, coalesce(v_cur.title,''));
          v_personal := hq_personal_chatwork_room_for_event(v_r, 'due_alert');
          if v_personal is not null then
            v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || v_title; v_bodies := v_bodies || (coalesce(v_cur.title,'') || E'\n' || v_url);
          end if;
        end if;
      end loop;
      for v_ch in
        select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
        join hq_notify_channels c on c.id = any(r.channel_ids)
        where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event='due_alert'
          and (r.target_corp is null or r.target_corp=v_task.corp)
          and (r.target_freq is null or r.target_freq=v_task.freq)
          and (r.target_template_id is null or r.target_template_id=v_task.template_id)
      loop
        v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || v_title; v_bodies := v_bodies || (coalesce(v_cur.title,'') || E'\n' || v_url);
      end loop;
    end if;

    select s.completed_at into v_since from hq_task_steps s where s.task_id=v_task.id and s.sort_order < v_cur.sort_order order by s.sort_order desc limit 1;
    if v_since is null then v_since := v_task.created_at; end if;
    v_stalled_days := floor(extract(epoch from (now() - v_since))/86400);
    if v_stalled_days >= 3 and coalesce(v_alert.overdue_daily, true) and not exists(
      select 1 from hq_notifications n where n.task_id=v_task.id and n.kind='stalled' and n.created_at::date = v_today
    ) then
      foreach v_r in array v_recipients loop
        if v_r is not null then
          insert into hq_notifications(recipient_id, task_id, kind, title, body) values (v_r, v_task.id, 'stalled', '停滞: ' || v_task.title, v_stalled_days || '日停止');
          v_personal := hq_personal_chatwork_room_for_event(v_r, 'stalled');
          if v_personal is not null then
            v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || ('停滞: '||v_task.title); v_bodies := v_bodies || ((v_stalled_days || '日停止') || E'\n' || v_url);
          end if;
        end if;
      end loop;
      for v_ch in
        select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
        join hq_notify_channels c on c.id = any(r.channel_ids)
        where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event='stalled'
          and (r.target_corp is null or r.target_corp=v_task.corp)
          and (r.target_freq is null or r.target_freq=v_task.freq)
          and (r.target_template_id is null or r.target_template_id=v_task.template_id)
      loop
        v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || ('停滞: '||v_task.title); v_bodies := v_bodies || ((v_stalled_days || '日停止') || E'\n' || v_url);
      end loop;
    end if;
  end loop;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$function$
;

-- ---------- hq_check_payroll_task_item ----------
CREATE OR REPLACE FUNCTION public.hq_check_payroll_task_item(p_year_month text, p_kind text, p_person_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_caller users%rowtype;
  v_link payroll_task_links%rowtype;
  v_item hq_step_checklist_items%rowtype;
  v_total int; v_done int;
  v_task hq_tasks%rowtype;
  v_was_done boolean;
begin
  select * into v_caller from users u0 where u0.id = auth.uid() and u0.is_active;
  if v_caller.id is null or not (v_caller.is_master or v_caller.role in ('CEO','HQ','TENCHO','TEAM')) then
    raise exception '権限がありません';
  end if;
  if p_kind not in ('transfer','cash') then
    raise exception 'kindはtransferかcashを指定してください';
  end if;

  select * into v_link from payroll_task_links where year_month = p_year_month and kind = p_kind;
  if v_link.step_id is null then
    return jsonb_build_object('ok', false, 'reason', '対応する本部タスクが見つかりません（給料確定が未実行の可能性があります）');
  end if;

  select * into v_item from hq_step_checklist_items
   where step_id = v_link.step_id
     and replace(replace(title,' ',''),chr(12288),'') = replace(replace(p_person_name,' ',''),chr(12288),'');
  if v_item.id is null then
    return jsonb_build_object('ok', false, 'reason', p_person_name||' はこのタスクのチェック項目に見つかりません');
  end if;

  if v_item.checked_at is null then
    update hq_step_checklist_items set checked_at = now(), checked_by = auth.uid() where id = v_item.id;
  end if;

  select count(*), count(*) filter (where checked_at is not null) into v_total, v_done
    from hq_step_checklist_items where step_id = v_link.step_id;

  select * into v_task from hq_tasks where id = v_link.task_id;
  v_was_done := v_task.status = 'done';

  if v_total > 0 and v_total = v_done then
    update hq_task_steps set completed_at = coalesce(completed_at, now()), completed_by = coalesce(completed_by, auth.uid())
      where id = v_link.step_id;
    if not v_was_done then
      perform notify_lark('✅ '||v_task.title||' が完了しました（全'||v_total||'件チェック済み）');
    end if;
  end if;

  return jsonb_build_object('ok', true, 'checked', v_done, 'total', v_total);
end;
$function$
;

-- ---------- hq_notify_comment ----------
CREATE OR REPLACE FUNCTION public.hq_notify_comment(p_comment_id uuid)
 RETURNS TABLE(channel_kind text, target text, keyword text, title text, body text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_com record; v_task record; v_uid uuid;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_ch record; v_cw text; v_title text; v_body text; v_uname text; v_personal text;
  v_url text;
begin
  select * into v_com from hq_task_comments where id = p_comment_id;
  if v_com is null then return; end if;
  select * into v_task from hq_tasks where id = v_com.task_id;
  if v_task is null then return; end if;
  v_url := 'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || v_task.id;
  v_title := 'メンションされました: ' || v_task.title;

  foreach v_uid in array coalesce(v_com.mentions, '{}') loop
    if v_uid <> v_com.created_by then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_uid, v_task.id, 'mention', v_title, v_com.body);

      select account_id into v_cw from hq_user_chatwork where user_id = v_uid;
      select name into v_uname from users where id = v_uid;
      v_body := (case when v_cw is not null then '[To:'||v_cw||']' else coalesce(v_uname,'') end) || ' ' || v_com.body || E'\n' || v_url;

      v_personal := hq_personal_chatwork_room_for_event(v_uid, 'mention');
      if v_personal is not null then
        v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text;
        v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
      end if;

      for v_ch in
        select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
        join hq_notify_channels c on c.id = any(r.channel_ids)
        where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event='mention'
          and (r.target_corp is null or r.target_corp=v_task.corp)
          and (r.target_freq is null or r.target_freq=v_task.freq)
          and (r.target_template_id is null or r.target_template_id=v_task.template_id)
      loop
        v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,'');
        v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
      end loop;
    end if;
  end loop;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$function$
;

-- ---------- hq_notify_step_event ----------
CREATE OR REPLACE FUNCTION public.hq_notify_step_event(p_step_id uuid, p_event text)
 RETURNS TABLE(channel_kind text, target text, keyword text, title text, body text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_step record; v_task record; v_next record;
  v_title text; v_body text; v_recipient uuid; v_personal text;
  v_next_recipients uuid[]; v_r uuid;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_ch record;
  v_url text;
begin
  select * into v_step from hq_task_steps where id = p_step_id;
  if v_step is null then return; end if;
  select * into v_task from hq_tasks where id = v_step.task_id;
  if v_task is null then return; end if;
  v_url := 'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || v_task.id;
  v_recipient := null;

  if p_event = 'step_complete' then
    v_title := '工程完了: ' || v_task.title;
    v_body := v_step.title || ' が完了しました';
    select * into v_next from hq_task_steps where task_id=v_task.id and completed_at is null order by sort_order limit 1;
    if v_next is not null then
      v_next_recipients := coalesce(v_next.assignee_ids, case when v_next.assignee_id is not null then array[v_next.assignee_id] else null end);
      if v_next_recipients is not null and array_length(v_next_recipients,1) is not null then
        v_title := 'あなたの番です: '||v_task.title; v_body := v_next.title||'をお願いします';
        foreach v_r in array v_next_recipients loop
          if v_r is not null then
            insert into hq_notifications(recipient_id, task_id, kind, title, body)
            values (v_r, v_task.id, 'step_complete', v_title, v_body);
          end if;
        end loop;
      end if;
    end if;
  elsif p_event = 'issue_reported' then
    v_title := '異常あり: ' || v_task.title;
    v_body := v_step.title || ' — ' || coalesce(v_step.issue_note,'');
    if v_task.created_by is not null then
      insert into hq_notifications(recipient_id, task_id, kind, title, body)
      values (v_task.created_by, v_task.id, 'issue_reported', v_title, v_body);
      v_recipient := v_task.created_by;
    end if;
  else
    return;
  end if;

  v_body := v_body || E'\n' || v_url;

  if p_event = 'step_complete' and v_next_recipients is not null then
    foreach v_r in array v_next_recipients loop
      if v_r is not null then
        v_personal := hq_personal_chatwork_room_for_event(v_r, 'step_complete');
        if v_personal is not null then
          v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
        end if;
      end if;
    end loop;
  elsif v_recipient is not null then
    v_personal := hq_personal_chatwork_room_for_event(v_recipient, p_event);
    if v_personal is not null then
      v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
    end if;
  end if;

  for v_ch in
    select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
    join hq_notify_channels c on c.id = any(r.channel_ids)
    where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event=p_event
      and (r.target_corp is null or r.target_corp=v_task.corp)
      and (r.target_freq is null or r.target_freq=v_task.freq)
      and (r.target_template_id is null or r.target_template_id=v_task.template_id)
  loop
    v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
  end loop;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$function$
;

-- ---------- hq_notify_task_urgent ----------
CREATE OR REPLACE FUNCTION public.hq_notify_task_urgent(p_task_id uuid)
 RETURNS TABLE(channel_kind text, target text, keyword text, title text, body text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_task record; v_cur record;
  v_recipients uuid[]; v_r uuid;
  v_title text; v_body text; v_url text; v_personal text;
  v_kinds text[] := '{}'; v_targets text[] := '{}'; v_kws text[] := '{}'; v_titles text[] := '{}'; v_bodies text[] := '{}';
  v_ch record;
begin
  select * into v_task from hq_tasks where id = p_task_id;
  if v_task is null then return; end if;
  v_url := 'https://mirai-oss.github.io/ns-portal/tasks.html?task=' || v_task.id;
  v_title := '🔥最重要: ' || v_task.title;

  select s.* into v_cur from hq_task_steps s where s.task_id = v_task.id and s.completed_at is null order by s.sort_order limit 1;
  v_body := (case when v_cur is not null then 'いま: ' || v_cur.title else '' end) || E'\n' || v_url;

  v_recipients := coalesce(v_cur.assignee_ids, case when v_cur.assignee_id is not null then array[v_cur.assignee_id] else null end, '{}'::uuid[]);
  if v_task.created_by is not null and not (v_task.created_by = any(v_recipients)) then
    v_recipients := v_recipients || v_task.created_by;
  end if;

  foreach v_r in array v_recipients loop
    if v_r is not null then
      insert into hq_notifications(recipient_id, task_id, kind, title, body) values (v_r, v_task.id, 'task_urgent', v_title, coalesce(v_cur.title,''));
      v_personal := hq_personal_chatwork_room_for_event(v_r, 'task_urgent');
      if v_personal is not null then
        v_kinds := v_kinds || 'chatwork'::text; v_targets := v_targets || v_personal; v_kws := v_kws || ''::text; v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
      end if;
    end if;
  end loop;

  for v_ch in
    select distinct c.kind as ckind, coalesce(c.webhook_url, c.room_id) as ctarget, c.keyword from hq_notify_rules r
    join hq_notify_channels c on c.id = any(r.channel_ids)
    where r.is_active and c.is_active and c.kind in ('lark_webhook','chatwork') and r.event='task_urgent'
      and (r.target_corp is null or r.target_corp=v_task.corp)
      and (r.target_freq is null or r.target_freq=v_task.freq)
      and (r.target_template_id is null or r.target_template_id=v_task.template_id)
  loop
    v_kinds := v_kinds || v_ch.ckind; v_targets := v_targets || v_ch.ctarget; v_kws := v_kws || coalesce(v_ch.keyword,''); v_titles := v_titles || v_title; v_bodies := v_bodies || v_body;
  end loop;

  return query select k,t,kw,ti,bo from unnest(v_kinds,v_targets,v_kws,v_titles,v_bodies) as x(k,t,kw,ti,bo);
end;
$function$
;

-- ---------- hq_personal_chatwork_room ----------
CREATE OR REPLACE FUNCTION public.hq_personal_chatwork_room(p_user_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select room_id from hq_user_chatwork where user_id = p_user_id and room_id is not null;
$function$
;

-- ---------- hq_personal_chatwork_room_for_event ----------
CREATE OR REPLACE FUNCTION public.hq_personal_chatwork_room_for_event(p_user_id uuid, p_event text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_room text;
begin
  -- ①そのイベントを明示的に含むルートを最優先
  select room_id into v_room from hq_user_notify_routes
    where user_id = p_user_id and p_event = any(events)
    order by sort_order limit 1;
  if v_room is not null then return v_room; end if;

  -- ②次に「その他すべて」ルート（events が空配列＝キャッチオール）
  select room_id into v_room from hq_user_notify_routes
    where user_id = p_user_id and coalesce(array_length(events,1),0) = 0
    order by sort_order limit 1;
  if v_room is not null then return v_room; end if;

  -- ③どちらも無ければ、従来どおりの単一ルーム設定（hq_user_chatwork）にフォールバック
  return (select room_id from hq_user_chatwork where user_id = p_user_id and room_id is not null);
end;
$function$
;

-- ---------- lark_route_test ----------
CREATE OR REPLACE FUNCTION public.lark_route_test(p_route uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare r lark_routes%rowtype;
begin
  if not exists(select 1 from users where id = auth.uid() and role in ('CEO','HQ')) then
    raise exception '権限がありません（社長・本部のみ）';
  end if;
  select * into r from lark_routes where id = p_route;
  if not found then raise exception '設定が見つかりません'; end if;
  perform notify_route_send(r.kind, r.webhook_url,
    '🐔【テスト】「' || r.name || '」の送信先として設定されています');
  return case when r.kind = 'chatwork'
    then 'Chatworkへ送信しました（数秒かかります）。届かない場合は設定画面の送信ログをご確認ください'
    else 'Larkへ送信しました。グループを確認してください' end;
end $function$
;

-- ---------- lark_test ----------
CREATE OR REPLACE FUNCTION public.lark_test()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare v_url text;
begin
  if not exists(select 1 from users where id = auth.uid() and role in ('CEO','HQ')) then
    raise exception '権限がありません（社長・本部のみ）';
  end if;
  select value into v_url from app_secrets where key = 'lark_webhook';
  if v_url is null or length(trim(v_url)) = 0 then
    return 'Lark通知は未設定です。Webhook URLを保存してからお試しください';
  end if;
  perform net.http_post(
    url := trim(v_url),
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object('msg_type','text','content',
      jsonb_build_object('text','🐔【テスト】鳥一代 日報システムからの通知テストです'))
  );
  return 'Larkへ送信しました。グループを確認してください（数秒かかることがあります）';
end $function$
;

-- ---------- notify_join_complete ----------
CREATE OR REPLACE FUNCTION public.notify_join_complete()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare v_uid uuid := auth.uid(); v_name text; v_role text; v_team uuid; v_email text;
        v_staff text; v_tpl text; v_extra text := ''; v_stores text;
        v_body text; r record; v_cnt int := 0;
begin
  if v_uid is null then return 0; end if;
  select u.name, u.role, u.team_id, u.email into v_name, v_role, v_team, v_email
    from users u where u.id = v_uid;
  if v_name is null then return 0; end if;

  select smaregi_staff_id into v_staff from employee_profiles where user_id = v_uid;
  select value into v_tpl from app_secrets where key = 'smaregi_staff_url';

  if v_staff is not null then
    v_extra := E'\n\n▼ スマレジ・タイムカードの設定をお願いします';
    if v_tpl is not null and length(trim(v_tpl)) > 0 then
      v_extra := v_extra || E'\n' || replace(trim(v_tpl), '{ID}', v_staff);
    else
      v_extra := v_extra || E'\n（従業員ID: ' || v_staff || E'）';
    end if;
    v_extra := v_extra || E'\n・時給／所属店舗' ||
               E'\n・メールアドレス: ' || coalesce(v_email, '（未登録）') ||
               E'\n　※メールを登録すると本人にログイン案内が自動送信されます';
  else
    v_extra := E'\n（スマレジ未登録。必要なら手動で登録してください）';
  end if;

  select coalesce(string_agg(s.name, '・' order by s.sort_order), '所属なし') into v_stores
    from stores s join user_stores us on us.store_id = s.id where us.user_id = v_uid;

  v_body := '🐔 ' || v_name || 'さんが入社登録を完了しました（' ||
    case v_role when 'AL' then 'アルバイト' when 'SHAIN' then '社員' when 'TENCHO' then '店長'
                when 'TEAM' then 'チーム長' when 'HQ' then '本部' when 'CEO' then '社長'
                else v_role end || '・' || v_stores || '）' || v_extra ||
    E'\n\nhttps://mirai-oss.github.io/nippo/';

  for r in
    select lr.* from lark_routes lr
     where lr.is_active and 'join_registered' = any(lr.events)
       and (lr.role is null or lr.role = v_role)
       and (lr.team_id is null or lr.team_id = v_team)
       and (lr.store_id is null or lr.store_id in
             (select us.store_id from user_stores us where us.user_id = v_uid))
     order by lr.sort_order, lr.created_at
  loop
    perform notify_route_send(r.kind, r.webhook_url, v_body);
    v_cnt := v_cnt + 1;
  end loop;
  return v_cnt;
end $function$
;

-- ---------- notify_join_resend ----------
CREATE OR REPLACE FUNCTION public.notify_join_resend(p_user uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare v_name text; v_role text; v_team uuid; v_email text;
        v_staff text; v_tpl text; v_extra text := ''; v_stores text;
        v_body text; r record; v_cnt int := 0;
begin
  if not exists (select 1 from users where id = auth.uid() and role in ('CEO','HQ')) then
    raise exception '権限がありません（社長・本部のみ）';
  end if;
  select u.name, u.role, u.team_id, u.email into v_name, v_role, v_team, v_email
    from users u where u.id = p_user;
  if v_name is null then raise exception '対象の従業員が見つかりません'; end if;
  select smaregi_staff_id into v_staff from employee_profiles where user_id = p_user;
  select value into v_tpl from app_secrets where key = 'smaregi_staff_url';
  if v_staff is not null then
    v_extra := E'\n\n▼ スマレジ・タイムカードの設定をお願いします';
    if v_tpl is not null and length(trim(v_tpl)) > 0 then
      v_extra := v_extra || E'\n' || replace(trim(v_tpl), '{ID}', v_staff);
    else
      v_extra := v_extra || E'\n（従業員ID: ' || v_staff || E'）';
    end if;
    v_extra := v_extra || E'\n・時給／所属店舗' ||
               E'\n・メールアドレス: ' || coalesce(v_email, '（未登録）') ||
               E'\n　※メールを登録すると本人にログイン案内が自動送信されます';
  else
    v_extra := E'\n（スマレジ未登録）';
  end if;
  select coalesce(string_agg(s.name, '・' order by s.sort_order), '所属なし') into v_stores
    from stores s join user_stores us on us.store_id = s.id where us.user_id = p_user;
  v_body := '🐔 ' || v_name || 'さんの入社情報（再送）（' ||
    case v_role when 'AL' then 'アルバイト' when 'SHAIN' then '社員' when 'TENCHO' then '店長'
                when 'TEAM' then 'チーム長' when 'HQ' then '本部' when 'CEO' then '社長'
                else v_role end || '・' || v_stores || '）' || v_extra ||
    E'\n\nhttps://mirai-oss.github.io/nippo/';
  for r in
    select lr.* from lark_routes lr
     where lr.is_active and 'join_registered' = any(lr.events)
       and (lr.role is null or lr.role = v_role)
       and (lr.team_id is null or lr.team_id = v_team)
       and (lr.store_id is null or lr.store_id in
             (select us.store_id from user_stores us where us.user_id = p_user))
     order by lr.sort_order, lr.created_at
  loop
    perform notify_route_send(r.kind, r.webhook_url, v_body);
    v_cnt := v_cnt + 1;
  end loop;
  return v_cnt;
end $function$
;

-- ---------- notify_lark ----------
CREATE OR REPLACE FUNCTION public.notify_lark(p_text text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare v_url text; v_req bigint;
begin
  select value into v_url from app_secrets where key = 'lark_webhook';
  if v_url is null or length(trim(v_url)) = 0 then
    insert into lark_log(ok, message, detail) values (false, left(p_text,300), 'Webhook URLが未設定');
    return;
  end if;
  begin
    select net.http_post(
      url := trim(v_url),
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object('msg_type','text','content',jsonb_build_object('text',p_text))
    ) into v_req;
    insert into lark_log(ok, message, detail) values (true, left(p_text,300), 'request_id=' || coalesce(v_req::text,'?'));
  exception when others then
    insert into lark_log(ok, message, detail) values (false, left(p_text,300), SQLERRM);
  end;
end $function$
;

-- ---------- notify_lark_url ----------
CREATE OR REPLACE FUNCTION public.notify_lark_url(p_url text, p_text text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
begin
  begin
    perform net.http_post(url := trim(p_url),
      headers := '{"Content-Type":"application/json"}'::jsonb,
      body := jsonb_build_object('msg_type','text','content',jsonb_build_object('text',p_text)));
    insert into lark_log(ok, message, detail) values (true, left(p_text,300), '日報通知');
  exception when others then
    insert into lark_log(ok, message, detail) values (false, left(p_text,300), SQLERRM);
  end;
end $function$
;

-- ---------- notify_report_lark ----------
CREATE OR REPLACE FUNCTION public.notify_report_lark(p_report uuid, p_body text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare v_rep reports%rowtype; v_role text; v_team uuid; v_ev text; r record; v_cnt int := 0;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select * into v_rep from reports where id = p_report;
  if not found then return 0; end if;
  if v_rep.author_id <> auth.uid()
     and not exists(select 1 from users where id = auth.uid() and role in ('CEO','HQ')) then
    raise exception '権限がありません';
  end if;
  if p_body is null or length(trim(p_body)) = 0 then return 0; end if;
  if length(p_body) > 6000 then p_body := left(p_body, 6000) || E'\n…（省略）'; end if;
  v_ev := 'report_' || v_rep.kind;
  select role, team_id into v_role, v_team from users where id = v_rep.author_id;
  for r in
    select lr.* from lark_routes lr
     where lr.is_active and v_ev = any(lr.events)
       and (lr.role is null or lr.role = v_role)
       and (lr.team_id is null or lr.team_id = v_team)
       and (lr.store_id is null or lr.store_id in
             (select us.store_id from user_stores us where us.user_id = v_rep.author_id))
     order by lr.sort_order, lr.created_at
  loop
    perform notify_route_send(r.kind, r.webhook_url, p_body);
    v_cnt := v_cnt + 1;
  end loop;
  return v_cnt;
end $function$
;

-- ---------- notify_route_send ----------
CREATE OR REPLACE FUNCTION public.notify_route_send(p_kind text, p_target text, p_text text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare v_token text;
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/smaregi-sync';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  c_key  constant text := (select value from app_secrets where key = 'checklist_intake_secret');
begin
  if p_target is null or length(trim(p_target)) = 0 then return; end if;
  begin
    if p_kind = 'chatwork' then
      select value into v_token from app_secrets where key = 'chatwork_token';
      if v_token is null or length(trim(v_token)) = 0 then
        insert into lark_log(ok, message, detail) values (false, left(p_text,300), 'Chatworkのトークン未設定');
        return;
      end if;
      -- Edge Function に中継（実際の送信結果は Edge Function 側が lark_log に記録する）
      perform net.http_post(
        url := c_fn,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'apikey', c_anon,
          'Authorization', 'Bearer ' || c_anon),
        body := jsonb_build_object(
          'action', 'notify_chatwork',
          'secret', c_key,
          'room', trim(p_target),
          'text', p_text,
          'token', trim(v_token))
      );
    else
      perform net.http_post(
        url := trim(p_target),
        headers := '{"Content-Type":"application/json"}'::jsonb,
        body := jsonb_build_object('msg_type','text','content',jsonb_build_object('text',p_text))
      );
      insert into lark_log(ok, message, detail) values (true, left(p_text,300), 'Lark');
    end if;
  exception when others then
    insert into lark_log(ok, message, detail) values (false, left(p_text,300), SQLERRM);
  end;
end $function$
;

-- ---------- resolve_store ----------
CREATE OR REPLACE FUNCTION public.resolve_store(p_source text, p_external_id text DEFAULT NULL::text, p_code text DEFAULT NULL::text, p_name text DEFAULT NULL::text, p_corp_hint text DEFAULT NULL::text, p_log boolean DEFAULT true, p_as_of date DEFAULT NULL::date)
 RETURNS TABLE(store_id uuid, brand_id uuid, corporation_id uuid, confidence text, matched_by text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_today date := coalesce(p_as_of, (now() at time zone 'Asia/Tokyo')::date);
  v_hint_corp uuid := smv2_corp_id_from_hint(p_corp_hint);
  v_n text := smv2_norm(p_name);
  v_store uuid; v_brand uuid; v_map public.store_external_mappings%rowtype;
  v_conf text; v_by text; v_cnt int;
  v_ids uuid[];
begin
  -- ①〜③ 外部マッピング（有効・期間内）。スマレジ系（契約ごとに店舗IDを採番）は契約＝法人ヒントで絞り、
  --   絞れず複数店舗に当たる場合は誤って当てずに次の段へ（smv2_pick_mapping）
  if p_external_id is not null and btrim(p_external_id) <> '' then
    select m.* into v_map from public.smv2_pick_mapping(p_source, 'id', btrim(p_external_id), v_hint_corp, v_today) m;
    if found then v_store := v_map.store_id; v_brand := v_map.brand_id; v_conf := 'exact'; v_by := 'mapping:external_id'; end if;
  end if;
  if v_store is null and p_code is not null and btrim(p_code) <> '' then
    select m.* into v_map from public.smv2_pick_mapping(p_source, 'code', btrim(p_code), v_hint_corp, v_today) m;
    if found then v_store := v_map.store_id; v_brand := v_map.brand_id; v_conf := 'exact'; v_by := 'mapping:code'; end if;
  end if;
  if v_store is null and p_name is not null and btrim(p_name) <> '' then
    select m.* into v_map from public.smv2_pick_mapping(p_source, 'name', btrim(p_name), v_hint_corp, v_today) m;
    if found then v_store := v_map.store_id; v_brand := v_map.brand_id; v_conf := 'exact'; v_by := 'mapping:name'; end if;
  end if;

  -- ④ stores.name（正規化一致。同名が複数なら法人ヒントで絞る。絞れなければ未確定）
  if v_store is null and v_n <> '' then
    select array_agg(s.id) into v_ids from public.stores s where smv2_norm(s.name) = v_n or smv2_norm(s.display_name) = v_n;
    v_cnt := coalesce(array_length(v_ids,1),0);
    if v_cnt > 1 and v_hint_corp is not null then
      select array_agg(s.id) into v_ids from public.stores s
        where s.id = any(v_ids) and (s.corporation_id = v_hint_corp);
      v_cnt := coalesce(array_length(v_ids,1),0);
    end if;
    if v_cnt = 1 then v_store := v_ids[1]; v_conf := 'high'; v_by := 'store_name'; end if;
  end if;

  -- ⑤ store_aliases（正規化一致）
  if v_store is null and v_n <> '' then
    select array_agg(distinct a.store_id) into v_ids from public.store_aliases a where smv2_norm(a.alias) = v_n;
    v_cnt := coalesce(array_length(v_ids,1),0);
    if v_cnt > 1 and v_hint_corp is not null then
      select array_agg(s.id) into v_ids from public.stores s where s.id = any(v_ids) and s.corporation_id = v_hint_corp;
      v_cnt := coalesce(array_length(v_ids,1),0);
    end if;
    if v_cnt = 1 then v_store := v_ids[1]; v_conf := 'high'; v_by := 'store_alias'; end if;
  end if;

  -- ⑥ 正規化後の部分一致（2文字以上・候補がちょうど1店舗のときだけ。confidence='low'）
  if v_store is null and length(v_n) >= 2 then
    select array_agg(distinct c.sid) into v_ids from (
      select s.id as sid, smv2_norm(s.name) as nm from public.stores s
      union all select s.id, smv2_norm(s.display_name) from public.stores s where s.display_name is not null
      union all select a.store_id, smv2_norm(a.alias) from public.store_aliases a
    ) c where c.nm <> '' and (position(v_n in c.nm) > 0 or position(c.nm in v_n) > 0)
      and length(c.nm) >= 2;
    v_cnt := coalesce(array_length(v_ids,1),0);
    if v_cnt > 1 and v_hint_corp is not null then
      select array_agg(s.id) into v_ids from public.stores s where s.id = any(v_ids) and s.corporation_id = v_hint_corp;
      v_cnt := coalesce(array_length(v_ids,1),0);
    end if;
    if v_cnt = 1 then v_store := v_ids[1]; v_conf := 'low'; v_by := 'partial'; end if;
  end if;

  -- ⑦ 未解決: 0行を返し kd_unresolved_names へ1行記録（既存の隔離の仕組み・Lark通知は既存の kd-unresolved-check に乗る）
  if v_store is null then
    if p_log and coalesce(nullif(btrim(p_name),''), nullif(btrim(p_code),''), nullif(btrim(p_external_id),'')) is not null then
      perform public.kd_report_unresolved_name(
        'resolve_store:' || coalesce(p_source,'?'), 'store',
        coalesce(nullif(btrim(p_name),''), nullif(btrim(p_code),''), btrim(p_external_id)),
        jsonb_build_object('external_id', p_external_id, 'code', p_code, 'corp_hint', p_corp_hint));
    end if;
    return;
  end if;

  select s.corporation_id into corporation_id from public.stores s where s.id = v_store;
  if corporation_id is null and v_map.corporation_hint is not null then
    corporation_id := smv2_corp_id_from_hint(v_map.corporation_hint);
  end if;
  if v_brand is null then
    select r.brand_id into v_brand from public.store_brand_relations r
      where r.store_id = v_store and r.is_primary and (r.effective_to is null or r.effective_to >= v_today) limit 1;
  end if;
  store_id := v_store; brand_id := v_brand; confidence := v_conf; matched_by := v_by;
  return next;
end $function$
;

-- ---------- trg_lark_notify ----------
CREATE OR REPLACE FUNCTION public.trg_lark_notify()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'net', 'extensions'
AS $function$
declare ev record; r record; v_role text; v_team uuid; v_extra text;
        v_staff text; v_tpl text; v_status text;
begin
  for ev in
    select distinct on (n.type, n.body_i18n->>'ja')
           n.type as etype, n.body_i18n->>'ja' as ja,
           case when n.type = 'applicant_new' then null
                else coalesce(n.actor_id, n.recipient_id) end as who
      from new_rows n order by n.type, n.body_i18n->>'ja'
  loop
    v_role := null; v_team := null; v_extra := ''; v_status := null;
    if ev.who is not null then
      select role, team_id into v_role, v_team from users where id = ev.who;
    end if;

    if ev.etype = 'join_registered' and ev.who is not null then
      select smaregi_staff_id, smaregi_sync_status into v_staff, v_status
        from employee_profiles where user_id = ev.who;
      -- スマレジ登録の結果待ち → 送信は notify_join_complete に任せる
      if coalesce(v_status, 'pending') = 'pending' then
        continue;
      end if;
      select value into v_tpl from app_secrets where key = 'smaregi_staff_url';
      if v_staff is not null and v_tpl is not null and length(trim(v_tpl)) > 0 then
        v_extra := E'\n\n以下のリンクから時給・店舗の設定をお願いします\n' || replace(trim(v_tpl), '{ID}', v_staff);
      elsif v_staff is not null then
        v_extra := E'\n（スマレジの従業員ID: ' || v_staff || E'）';
      end if;
    end if;

    for r in
      select lr.* from lark_routes lr
       where lr.is_active and ev.etype = any(lr.events)
         and (lr.role is null or lr.role = v_role)
         and (lr.team_id is null or lr.team_id = v_team)
         and (lr.store_id is null or (ev.who is not null and lr.store_id in
               (select us.store_id from user_stores us where us.user_id = ev.who)))
       order by lr.sort_order, lr.created_at
    loop
      perform notify_route_send(r.kind, r.webhook_url,
        '🐔 ' || coalesce(ev.ja, 'お知らせ') || v_extra || E'\nhttps://mirai-oss.github.io/nippo/');
    end loop;
  end loop;
  return null;
end $function$
;
