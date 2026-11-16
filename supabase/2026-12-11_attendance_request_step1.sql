-- =============================================================
-- 勤怠修正申請 STEP 1・STEP 3（2026-11-16・社長の決定。担当D）
-- 状態: ★ 未適用 ★（社長の承認待ち。適用は SQL Editor か CLI で 1 回。何度流しても壊れません）
--
--   (1) 道A（朝の勤怠アラート →「修正する」）を、店舗別 2 段階承認（一次承認者 → 社長）の流れに乗せる
--       … 関数 sf_attendance_fix_request（アラートの修正申請の入口）を、スイッチ ON のとき「2 段階の申請を作ってアラートに結びつける」形に差し替える。
--         今までの本体は sf_attendance_fix_request_legacy に名前を変えて残す（スイッチ OFF のときは今までどおりそちらを呼ぶ）。
--       … 同じアラートから 2 つ申請は作れない（アラート側の request_id は一意・行ロック）。「○ 合っている」は変更なし。
--       … 結びついたアラートは、アラート側の承認・却下では動かせない（DB のトリガーで止める）。申請の結果（承認・却下・取り下げ）はアラートに自動で映る。
--   (2) 道N（日報サイトの「修正申請」。時刻なし）… 出たら #勤怠確認 に知らせる（その店舗の一次承認者にメンション。未設定の店舗は社長）。
--       通知の失敗は、日報サイトの送信を止めない。時刻が無いので、スマレジへ送る道は作らない（時刻の修正は、勤怠修正の申請フォームで出し直す）。
--   (3) 一次承認者が未設定の店舗（業務委託の 4 店など）は、一次承認を省略して社長へ直行（最終承認待ち）。退職などで無効の人が設定されている店舗は今までどおり「確認待ち」。
--   (4) 社長本人の勤怠を社長自身が申請したときだけ、承認を省略して反映（記録は残す）。サーバー側の条件: 申請者＝社長（役職 CEO）かつ 対象の勤怠＝申請者本人。
--       ほかの人の勤怠を社長が申請した場合は、今までどおりの最終承認。
-- ロールバック: 2026-12-11_attendance_request_step1_rollback.sql
-- 既存の SQL ファイルは書き換えない（このファイルを足すだけ）。
-- =============================================================

-- ============ 1. 一次承認者の決め方: 行が無い店舗は社長へ直行 ============
create or replace function public.sf_attendance_request_route(p_store uuid, p_requested_by uuid, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ap uuid; v_has boolean;
begin
  select exists (select 1 from sf_attendance_first_approvers where store_id = p_store) into v_has;
  if not v_has then   -- 一次承認者を置かない店舗（業務委託の 4 店など）: 一次承認を省略して社長へ（2026-11-16 社長の決定）
    return jsonb_build_object('stage', 'final_wait', 'first_approver_id', null, 'first_skipped', true);
  end if;
  select a.approver_user_id into v_ap
    from sf_attendance_first_approvers a join users u on u.id = a.approver_user_id
   where a.store_id = p_store and u.is_active and u.deactivated_at is null;
  if v_ap is null then   -- 設定はあるが、その人が退職・無効: 勝手に社長へ送らず「確認待ち」（今までどおり）
    return jsonb_build_object('stage', 'hold', 'first_approver_id', null, 'first_skipped', false);
  end if;
  if coalesce(v_ap = p_requested_by, false) or coalesce(v_ap = p_user, false) then
    return jsonb_build_object('stage', 'final_wait', 'first_approver_id', v_ap, 'first_skipped', true);
  end if;
  return jsonb_build_object('stage', 'first_wait', 'first_approver_id', v_ap, 'first_skipped', false);
end $$;
revoke all on function public.sf_attendance_request_route(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_route(uuid, uuid, uuid) to service_role;

-- ============ 2. 道A: アラート ↔ 申請の結びつき ============
alter table sf_attendance_alerts add column if not exists request_id uuid references sf_attendance_requests(id) on delete set null;
create unique index if not exists sf_attendance_alerts_request_uq on sf_attendance_alerts (request_id) where request_id is not null;
comment on column sf_attendance_alerts.request_id is '「修正する」から作られた 2 段階承認の申請（sf_attendance_requests.id）。結びついている間は、アラート側の承認・却下はできない';

-- 守り: 結びついたアラートの状態は、申請の結果の同期（下のトリガー）からだけ変えられる
create or replace function public.sf_attendance_alerts_request_guard() returns trigger
language plpgsql set search_path = public as $$
begin
  if old.request_id is not null and old.status = 'fix_requested' and new.status is distinct from old.status
     and coalesce(current_setting('sf_att.alert_sync', true), '') <> 'on' then
    raise exception 'この勤怠確認は修正申請の承認の流れに進んでいます。申請のスレッド（または管理システムの申請画面）で操作してください';
  end if;
  return new;
end $$;
drop trigger if exists sf_attendance_alerts_request_guard_bu on sf_attendance_alerts;
create trigger sf_attendance_alerts_request_guard_bu before update on sf_attendance_alerts
  for each row execute function public.sf_attendance_alerts_request_guard();

-- 申請の結果をアラートに映す（承認 → approved・却下 → rejected・取り下げ → open に戻して出し直せるように）。失敗しても申請の処理は止めない
create or replace function public.sf_attendance_requests_alert_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is not distinct from old.status and new.smaregi_sync_status is not distinct from old.smaregi_sync_status
     and new.smaregi_error is not distinct from old.smaregi_error then
    return null;
  end if;
  if not exists (select 1 from sf_attendance_alerts where request_id = new.id) then return null; end if;
  begin
    perform set_config('sf_att.alert_sync', 'on', true);
    if new.status in ('approved', 'rejected') then
      update sf_attendance_alerts
         set status = new.status, decided_by = new.decided_by, decided_at = new.decided_at, decision_note = new.decision_note,
             applied_at = new.applied_at, smaregi_sync_status = new.smaregi_sync_status, smaregi_synced_at = new.smaregi_synced_at,
             smaregi_error = new.smaregi_error, updated_at = now()
       where request_id = new.id;
    elsif new.status = 'cancelled' then
      update sf_attendance_alerts
         set status = 'open', request_id = null, requested_by = null, requested_at = null, fix_reason = null,
             proposed_clock_in = null, proposed_clock_out = null,
             proposed_break_start_1 = null, proposed_break_end_1 = null, proposed_break_start_2 = null, proposed_break_end_2 = null, updated_at = now()
       where request_id = new.id;
    end if;
  exception when others then
    raise warning 'sf_attendance_requests_alert_sync: %', sqlerrm;
  end;
  perform set_config('sf_att.alert_sync', '', true);
  return null;
end $$;
drop trigger if exists sf_attendance_requests_alert_sync_au on sf_attendance_requests;
create trigger sf_attendance_requests_alert_sync_au after update on sf_attendance_requests
  for each row execute function public.sf_attendance_requests_alert_sync();

-- アラートの「修正する」の入口。今までの本体は _legacy に名前を変えて残す（スイッチ OFF のとき・ロールバックのとき用）
do $$
begin
  if to_regprocedure('public.sf_attendance_fix_request_legacy(uuid,uuid,timestamptz,timestamptz,text,text,timestamptz,timestamptz,timestamptz,timestamptz)') is null then
    alter function public.sf_attendance_fix_request(uuid, uuid, timestamptz, timestamptz, text, text, timestamptz, timestamptz, timestamptz, timestamptz)
      rename to sf_attendance_fix_request_legacy;
  end if;
end $$;

create or replace function public.sf_attendance_fix_request(
  p_alert_id uuid, p_actor uuid, p_clock_in timestamptz, p_clock_out timestamptz, p_reason text, p_via text default 'slack',
  p_break_start_1 timestamptz default null, p_break_end_1 timestamptz default null,
  p_break_start_2 timestamptz default null, p_break_end_2 timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_set jsonb; a sf_attendance_alerts%rowtype; v_res jsonb; v_req uuid; v_name text; v_prev text;
begin
  select value into v_set from app_settings where key = 'attendance_request_flow';
  if not (coalesce((v_set -> 'thread') = 'true'::jsonb, false) and coalesce((v_set -> 'two_stage') = 'true'::jsonb, false)) then
    return public.sf_attendance_fix_request_legacy(p_alert_id, p_actor, p_clock_in, p_clock_out, p_reason, p_via,
      p_break_start_1, p_break_end_1, p_break_start_2, p_break_end_2);
  end if;
  select name into v_name from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  select * into a from sf_attendance_alerts where id = p_alert_id for update;   -- 行ロック: 同時に 2 回押されても、申請は 1 つだけ
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この勤怠確認は見つかりません'); end if;
  if a.request_id is not null and a.status = 'fix_requested' then
    return jsonb_build_object('ok', false, 'code', 'already', 'message', 'この勤怠確認は、すでに修正申請が出ています（承認待ち）', 'request_id', a.request_id);
  end if;
  if a.status not in ('open', 'confirmed') then
    select name into v_prev from users where id = coalesce(a.requested_by, a.decided_by);
    return jsonb_build_object('ok', false, 'code', 'already', 'message', format('この勤怠確認はすでに処理されています（%s・%s）', a.status, coalesce(v_prev, '-')));
  end if;
  if not sf_can_manage_as(p_actor, a.store_id) then
    return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', 'この店舗の勤怠を修正する権限がありません');
  end if;
  -- 時刻・休憩・理由の検査と、申請の作成（2 段階の流れ・一次承認者の決定は、申請の表のトリガーが行う）
  v_res := public.sf_attendance_request_submit(p_actor, 'fix', a.store_id, a.user_id, a.work_date, p_clock_in, p_clock_out, p_reason,
    p_break_start_1, p_break_end_1, p_break_start_2, p_break_end_2, coalesce(p_via, 'form'));
  if coalesce((v_res ->> 'ok')::boolean, false) is not true then return v_res; end if;
  v_req := (v_res ->> 'request_id')::uuid;
  update sf_attendance_alerts
     set status = 'fix_requested', request_id = v_req, proposed_clock_in = p_clock_in, proposed_clock_out = p_clock_out, fix_reason = trim(p_reason),
         proposed_break_start_1 = p_break_start_1, proposed_break_end_1 = p_break_end_1,
         proposed_break_start_2 = p_break_start_2, proposed_break_end_2 = p_break_end_2,
         requested_by = p_actor, requested_at = now(), updated_at = now()
   where id = a.id;
  return jsonb_build_object('ok', true, 'alert_id', a.id, 'request_id', v_req, 'summary', sf_attendance_alert_summary(a), 'actor_name', v_name,
    'proposed', v_res ->> 'summary', 'reason', trim(p_reason), 'notification_ids', to_jsonb(a.notification_ids));
end $$;
revoke all on function public.sf_attendance_fix_request(uuid, uuid, timestamptz, timestamptz, text, text, timestamptz, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.sf_attendance_fix_request(uuid, uuid, timestamptz, timestamptz, text, text, timestamptz, timestamptz, timestamptz, timestamptz) to service_role;
revoke all on function public.sf_attendance_fix_request_legacy(uuid, uuid, timestamptz, timestamptz, text, text, timestamptz, timestamptz, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.sf_attendance_fix_request_legacy(uuid, uuid, timestamptz, timestamptz, text, text, timestamptz, timestamptz, timestamptz, timestamptz) to service_role;

-- ============ 3. 社長本人の勤怠を社長が申請したとき: 承認を省略して反映（記録は残す） ============
--   Edge Function（service_role）が、申請を作った直後に呼ぶ。条件の検査はここ（DB）で行う（画面・Slack の出し分けには頼らない）。
--   条件: 申請者の役職が CEO ・ 対象の勤怠が申請者本人 ・ まだ承認待ちの 2 段階の申請。ほかの人の勤怠・社長以外の申請は、何もしない（applied=false）。
--   反映は今ある承認の関数（sf_attendance_request_decide）をそのまま使う。スマレジへの書き戻しは Edge Function が今までの経路（smaregi-attendance-fix）で行う。
create or replace function public.sf_attendance_request_self_apply(p_request_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r sf_attendance_requests%rowtype; v_role text; v_res jsonb; c_note constant text := '本人（社長）の申請のため承認を省略';
begin
  select * into r from sf_attendance_requests where id = p_request_id for update;
  if not found then return jsonb_build_object('ok', false, 'applied', false, 'code', 'not_found', 'message', 'この申請は見つかりません'); end if;
  if r.status <> 'pending' or r.flow is distinct from 'two_stage' then return jsonb_build_object('ok', true, 'applied', false); end if;
  select role into v_role from users where id = r.requested_by and is_active;
  if coalesce(v_role, '') <> 'CEO' or r.requested_by is distinct from r.user_id then return jsonb_build_object('ok', true, 'applied', false); end if;
  perform set_config('sf_att.op', r.id::text, true);
  v_res := sf_attendance_request_decide(r.id, r.requested_by, true, c_note, 'system');
  if coalesce((v_res ->> 'ok')::boolean, false) is not true then
    perform set_config('sf_att.op', '', true);
    return jsonb_build_object('ok', false, 'applied', false, 'code', v_res ->> 'code', 'message', v_res ->> 'message');
  end if;
  update sf_attendance_requests set stage = null, updated_at = now() where id = r.id;
  insert into sf_attendance_request_events(request_id, actor, action, via, note) values (r.id, r.requested_by, 'president_self_apply', 'system', c_note);
  perform set_config('sf_att.op', '', true);
  return jsonb_build_object('ok', true, 'applied', true, 'request_id', r.id, 'state', (select sf_attendance_request_state(x) from sf_attendance_requests x where x.id = r.id));
end $$;
revoke all on function public.sf_attendance_request_self_apply(uuid) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_self_apply(uuid) to service_role;

-- ============ 4. 道N: 日報サイトの「修正申請」（時刻なし）が出たら #勤怠確認 に知らせる ============
--   スマレジへ送る道は作らない（時刻が無い）。通知はお知らせだけ。失敗しても、日報サイトの送信（insert）は止めない。
--   宛先: その店舗の一次承認者（有効な人）。設定が無い・無効のときは社長。スイッチ attendance_request_flow の thread が ON のときだけ動く。
create or replace function public.sf_attendance_correction_notice() returns trigger
language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/notify-slack';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  v_set jsonb; v_secret text; v_to uuid; v_sid text; v_store text; v_user text; v_kind text; v_text text;
begin
  begin
    select value into v_set from app_settings where key = 'attendance_request_flow';
    if not coalesce((v_set -> 'thread') = 'true'::jsonb, false) then return null; end if;
    select value into v_secret from app_secrets where key = 'notify_slack_secret';
    if v_secret is null or length(trim(v_secret)) = 0 then raise warning 'sf_attendance_correction_notice: notify_slack_secret が未設定'; return null; end if;
    select a.approver_user_id into v_to
      from sf_attendance_first_approvers a join users u on u.id = a.approver_user_id
     where a.store_id = new.store_id and u.is_active and u.deactivated_at is null;
    if v_to is null then select id into v_to from users where role = 'CEO' and is_active order by created_at limit 1; end if;
    select slack_user_id into v_sid from user_slack where user_id = v_to;
    select name into v_store from stores where id = new.store_id;
    select name into v_user from users where id = new.user_id;
    v_kind := case new.kind when 'late' then '遅刻' when 'early_leave' then '早退' when 'absence' then '欠勤' else 'その他' end;
    v_text := format(E'🙋 勤怠の修正申請（日報サイトから・時刻の入力なし）\n店舗：%s／対象：%s／日付：%s／種類：%s\n理由：%s\n%s時刻の修正が必要なときは、こちらから「勤怠修正」を申請してください（承認の流れは同じです）→ %s',
      coalesce(v_store, '-'), coalesce(v_user, '-'), to_char(new.work_date, 'MM/DD'), v_kind, left(coalesce(new.reason, ''), 200),
      case when v_sid ~ '^[UW][A-Z0-9]{6,}$' then '<@' || v_sid || E'> ' else '' end,
      'https://mirai-oss.github.io/ns-portal/kintai.html?store=' || new.store_id || '&date=' || new.work_date || '&user=' || new.user_id);
    perform net.http_post(
      url := c_fn,
      headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
      body := jsonb_build_object('action', 'send', 'channel_key', 'kintai.check', 'text', v_text, 'event', 'attendance_correction_notice',
        'source', 'db:sf_attendance_correction_requests', 'dedupe_key', 'attendance_corr:' || new.id, 'ref', jsonb_build_object('table', 'sf_attendance_correction_requests', 'id', new.id)),
      timeout_milliseconds := 30000);
  exception when others then
    raise warning 'sf_attendance_correction_notice: %', sqlerrm;   -- 通知の失敗は握りつぶす（日報サイトの送信を止めない）
  end;
  return null;
end $$;
revoke all on function public.sf_attendance_correction_notice() from public, anon, authenticated;
drop trigger if exists sf_attendance_correction_notice_ai on sf_attendance_correction_requests;
create trigger sf_attendance_correction_notice_ai after insert on sf_attendance_correction_requests
  for each row execute function public.sf_attendance_correction_notice();

-- ============ 5. 申請の履歴・承認待ちの件数: 「修正する」から作られた申請は、申請の側だけに数える（アラート側と二重に出さない） ============
--   本番の現在の定義（pg_get_functiondef）に、アラートの行から「申請に結びついたもの」（request_id あり）を除く条件を足しただけ。
--   ロールバックでは、足した条件を外した定義に戻す（下の rollback ファイル）。
CREATE OR REPLACE FUNCTION public.request_history(p_month text)
 RETURNS TABLE(kind text, occurred_at timestamp with time zone, requester text, summary text, amount numeric, status text, decided_at timestamp with time zone, decided_by text, store text, ref_id text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    where al.request_id is null and al.status in ('fix_requested', 'approved', 'rejected') and al.requested_at is not null and al.requested_at >= v_from and al.requested_at < v_to
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
$function$;

CREATE OR REPLACE FUNCTION public.request_pending_counts()
 RETURNS TABLE(kind text, n bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    select 'attendance'::text, (select count(*) from public.sf_attendance_requests a where a.status = 'pending') + (select count(*) from public.sf_attendance_alerts al where al.status = 'fix_requested' and al.request_id is null)   -- 2026-11-08(2) フォーム申請＋アラートからの修正/削除の承認待ち
    union all
    select 'attendance_change'::text, count(*) from public.sf_attendance_smaregi_changes c where c.status = 'open';   -- スマレジ直接修正の未確認（Slack の「○ 確認した」待ち）
end;
$function$;
