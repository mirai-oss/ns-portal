-- =============================================================
-- 2026-11-14 勤怠実績 labor_cost_daily.worked_minutes を「拘束時間」にそろえる（承認のときも拘束時間を保存する）
-- ★ 本番未適用（下書き）。適用はユーザー承認のあと: python3 scripts/apply_sql.py supabase/2026-11-14_worked_minutes_duty.sql（先に --dry-run）
-- 戻し方: supabase/2026-11-14_worked_minutes_duty_rollback.sql を流す（変更前の 3 関数の定義をそのまま入れてある）
--
-- 言葉:
--   拘束時間＝退勤−出勤／休憩時間＝登録された休憩の合計／実労働時間＝拘束時間−休憩時間
--
-- 目的（ユーザー決定 2026-11-11）:
--   worked_minutes に、処理によって違う意味の値が入っていた。
--     ・スマレジからの取り込み（smaregi-attendance-sync）……拘束時間（これが基準）
--     ・勤怠確認からの修正の承認（sf_attendance_fix_decide）・勤怠フォームの申請の承認（sf_attendance_request_decide）……実労働時間
--     ・休憩の自動補完（attendance_break_autofill_finish）……スマレジの読み直しの値が無いときの代わりの値だけ、実労働時間
--   これを「どの処理でも拘束時間」にそろえる。「実働」「休憩除く」と表示する所は、拘束時間から休憩時間を引いて表示する（画面・通知の側で直す）。
--
-- 変えた所（この 3 関数の、下に書いた所だけ。ほかは変更前の定義と 1 文字も変えていない）:
--   1) sf_attendance_fix_decide（修正の承認。打刻削除の分岐は変えていない）
--        ・worked_minutes に入れる値: 実労働時間（v_min）→ 拘束時間（v_duty＝退勤−出勤・分・四捨五入）
--        ・smaregi_estimate_cost（概算人件費）の按分: 元の値 × v_min ÷ 元の worked_minutes
--            → 元の値 × v_min（新しい実労働時間）÷（元の worked_minutes − 元の break_minutes）（実労働時間どうしの比）。分母が 0 以下・null なら元の値のまま
--        ・変数 v_duty を 1 つ足した
--   2) sf_attendance_request_decide（フォームの申請の承認。修正 fix と追加 add）
--        ・worked_minutes に入れる値（fix の更新・add の新しい行の両方）: v_min → v_duty（拘束時間）
--        ・smaregi_estimate_cost の按分（fix だけ。add は今までどおり null）: 1) と同じ式に
--        ・変数 v_duty を 1 つ足した
--   3) attendance_break_autofill_finish（休憩の自動補完の、管理システム側への反映）
--        ・スマレジの読み直しの値（p_duty_minute）が無いときの代わりの値: worked_minutes − 推定の休憩 → worked_minutes（変えない）
--
-- 変えていない所: 引数・返り値・security definer・search_path・権限の検査・状態の検査・返す内容・orig_ 列・手修正のロック・attendance_records の更新・打刻削除。
--   休憩が無い修正（元の勤怠にも休憩が無いとき）は、worked_minutes も概算人件費も、今までと同じ値になる。
--
-- 過去データ: 変えない（一括変更はしない）。今までに承認で入った「実労働時間」の値は、その勤怠がスマレジから取り込み直されたときに拘束時間に置き換わる。
--   手修正のロックが残っている勤怠（スマレジへの書き戻しが済んでいないもの）は、実労働時間のまま残る。
--
-- 基準にした定義（リポジトリのファイル。本番の定義と同じかどうかは、下の「0. 適用前の確かめ」が md5 で確かめる）:
--   sf_attendance_fix_decide ............ supabase/2026-11-08_attendance_delete_request.sql 64〜123 行（権限は 2026-11-07_sf_attendance_alerts.sql 248〜249 行）
--   sf_attendance_request_decide ........ supabase/2026-11-07_sf_attendance_requests.sql 167〜215 行（権限は同じファイルの 216〜217 行）
--   attendance_break_autofill_finish .... supabase/2026-11-13_break_autofill.sql 165〜188 行（権限は同じファイルの 280〜284 行のうち、この関数の分）
-- =============================================================

-- ============ 0. 適用前の確かめ（本番の定義が、基準にした定義と同じか） ============
--   本番の関数の本体（pg_proc.prosrc）の md5 が「変更前（基準にしたリポジトリの定義）」か「変更後（このファイル）」のどちらかでなければ、何も変えずに止まる。
--   止まったとき: 本番の定義がリポジトリのファイルと違う（別の変更が入っている）ということ。本番の定義を読んで違いを確かめ、このファイルを作り直す。
do $guard$
declare r record; v_md5 text; v_bad text := '';
begin
  for r in select * from (values
      ('sf_attendance_fix_decide', 'public.sf_attendance_fix_decide(uuid,uuid,boolean,text,text)', '324fc71a207d428e6ee1d342b6a592a7', 'ba525b88114ae749e89655ceaefd7da1'),
      ('sf_attendance_request_decide', 'public.sf_attendance_request_decide(uuid,uuid,boolean,text,text)', '67a7546c934348c8ebd79e89b15fe0b6', '0036f96ebeadfac50971f9e7d01e2dd3'),
      ('attendance_break_autofill_finish', 'public.attendance_break_autofill_finish(uuid,text,text,jsonb,numeric,numeric)', 'cd99182628c239eb4423942460fff7c7', 'fb29a1d6637455b4e9001ee9edc53ce1')
    ) as t(nm, sig, md5_before, md5_after) loop
    if to_regprocedure(r.sig) is null then
      v_bad := v_bad || r.nm || '（関数が無い）　';
    else
      select md5(p.prosrc) into v_md5 from pg_proc p where p.oid = to_regprocedure(r.sig);
      if v_md5 not in (r.md5_before, r.md5_after) then v_bad := v_bad || r.nm || '（本番の定義が基準と違う md5=' || v_md5 || '）　'; end if;
    end if;
  end loop;
  if v_bad <> '' then raise exception '適用を止めました。本番の定義を確かめてください: %', v_bad; end if;
end $guard$;

-- ============ 1. 勤怠確認からの修正の承認（打刻削除の分岐は変更なし） ============
create or replace function public.sf_attendance_fix_decide(p_alert_id uuid, p_actor uuid, p_approve boolean, p_note text default null, p_via text default 'slack')
returns jsonb language plpgsql security definer set search_path = public as $$
declare a sf_attendance_alerts%rowtype; v_name text; v_master boolean; v_prev text; v_min numeric; v_break numeric; l labor_cost_daily%rowtype; v_est numeric; v_proposed text; v_duty numeric;
begin
  select name, coalesce(is_master, false) into v_name, v_master from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  if not v_master then return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', '承認できるのはマスターだけです'); end if;
  select * into a from sf_attendance_alerts where id = p_alert_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この修正申請は見つかりません'); end if;
  if a.status <> 'fix_requested' then
    select name into v_prev from users where id = a.decided_by;
    return jsonb_build_object('ok', false, 'code', 'already', 'message', format('この修正申請はすでに処理されています（%s・%s）', a.status, coalesce(v_prev, '-')));
  end if;

  if p_approve and a.request_kind = 'delete' then
    -- 打刻削除: 行の写しを控えてから、管理システムの勤怠実績と出勤記録を消す（スマレジ側は EF が deleted_shift_result_id で DELETE）
    select * into l from labor_cost_daily where id = a.labor_cost_daily_id for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'no_record', 'message', '元の勤怠実績が見つかりません（同期で消えた可能性）'); end if;
    update sf_attendance_alerts
       set deleted_shift_result_id = l.smaregi_shift_result_id, deleted_smaregi_staff_id = l.smaregi_staff_id, deleted_source = l.source, deleted_labor = to_jsonb(l),
           status = 'approved', decided_by = p_actor, decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), ''),
           applied_at = now(), updated_at = now()
     where id = a.id;
    delete from attendance_records where user_id = a.user_id and work_date = a.work_date;
    delete from labor_cost_daily where id = l.id;   -- FK は set null（アラート行は残る）
  elsif p_approve then
    select * into l from labor_cost_daily where id = a.labor_cost_daily_id for update;
    if not found then return jsonb_build_object('ok', false, 'code', 'no_record', 'message', '元の勤怠実績が見つかりません（同期で消えた可能性）'); end if;
    v_break := coalesce(extract(epoch from (a.proposed_break_end_1 - a.proposed_break_start_1)) / 60, 0)
             + coalesce(extract(epoch from (a.proposed_break_end_2 - a.proposed_break_start_2)) / 60, 0);
    v_min := round(extract(epoch from (a.proposed_clock_out - a.proposed_clock_in)) / 60 - v_break);
    v_duty := round(extract(epoch from (a.proposed_clock_out - a.proposed_clock_in)) / 60);   -- 2026-11-14: 拘束時間（退勤−出勤）。worked_minutes にはこちらを入れる（v_min＝実労働時間は按分にだけ使う）
    -- 2026-11-14: 概算人件費の按分は、実労働時間どうしの比（新しい実労働 ÷ 元の実労働＝元の worked_minutes − 元の休憩）。分母が 0 以下・null なら元の値のまま
    v_est := case when coalesce(l.worked_minutes - coalesce(l.break_minutes, 0), 0) > 0 and l.smaregi_estimate_cost is not null
                  then round(l.smaregi_estimate_cost * v_min / (l.worked_minutes - coalesce(l.break_minutes, 0))) else l.smaregi_estimate_cost end;
    update labor_cost_daily
       set orig_clock_in = coalesce(orig_clock_in, clock_in), orig_clock_out = coalesce(orig_clock_out, clock_out),
           orig_worked_minutes = coalesce(orig_worked_minutes, worked_minutes), orig_smaregi_estimate_cost = coalesce(orig_smaregi_estimate_cost, smaregi_estimate_cost),
           clock_in = a.proposed_clock_in, clock_out = a.proposed_clock_out, worked_minutes = v_duty, smaregi_estimate_cost = v_est,
           break_start_1 = a.proposed_break_start_1, break_end_1 = a.proposed_break_end_1,
           break_start_2 = a.proposed_break_start_2, break_end_2 = a.proposed_break_end_2, break_minutes = round(v_break),
           manual_fixed_at = now(), manual_fixed_by = p_actor, manual_fix_alert_id = a.id, updated_at = now()
     where id = l.id;
    update attendance_records set clock_in = a.proposed_clock_in, clock_out = a.proposed_clock_out
     where user_id = a.user_id and work_date = a.work_date;
    update sf_attendance_alerts set status = 'approved', decided_by = p_actor, decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), ''),
           applied_at = now(), updated_at = now() where id = a.id;
  else
    update sf_attendance_alerts set status = 'rejected', decided_by = p_actor, decided_at = now(), decision_note = nullif(trim(coalesce(p_note, '')), ''),
           updated_at = now() where id = a.id;
  end if;
  v_proposed := case when a.request_kind = 'delete' then '打刻削除（この日の勤務を取り消す）'
    else format('%s−%s（%s）',
      to_char(a.proposed_clock_in at time zone 'Asia/Tokyo', 'HH24:MI'),
      case when (a.proposed_clock_out at time zone 'Asia/Tokyo')::date > (a.proposed_clock_in at time zone 'Asia/Tokyo')::date then '翌' else '' end
        || to_char(a.proposed_clock_out at time zone 'Asia/Tokyo', 'HH24:MI'),
      sf_attendance_break_text(a.proposed_break_start_1, a.proposed_break_end_1, a.proposed_break_start_2, a.proposed_break_end_2)) end;
  return jsonb_build_object('ok', true, 'alert_id', a.id, 'approved', p_approve, 'request_kind', a.request_kind, 'summary', sf_attendance_alert_summary(a), 'actor_name', v_name,
    'proposed', v_proposed, 'reason', a.fix_reason, 'note', nullif(trim(coalesce(p_note, '')), ''),
    'requested_by_name', (select name from users where id = a.requested_by),
    'notification_ids', to_jsonb(a.notification_ids), 'approval_notification_ids', to_jsonb(a.approval_notification_ids));
end $$;
revoke all on function public.sf_attendance_fix_decide(uuid, uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_fix_decide(uuid, uuid, boolean, text, text) to service_role;

-- ============ 2. 勤怠フォームの申請の承認（修正＝更新・追加＝新しい行） ============
create or replace function public.sf_attendance_request_decide(p_request_id uuid, p_actor uuid, p_approve boolean, p_note text default null, p_via text default 'slack')
returns jsonb language plpgsql security definer set search_path = public as $$
declare r sf_attendance_requests%rowtype; v_name text; v_master boolean; v_prev text; v_min numeric; l labor_cost_daily%rowtype; v_est numeric; v_new uuid; v_duty numeric;
begin
  select name, coalesce(is_master, false) into v_name, v_master from users where id = p_actor and is_active;
  if v_name is null then return jsonb_build_object('ok', false, 'code', 'no_actor', 'message', '操作者が管理システムに見つかりません'); end if;
  if not v_master then return jsonb_build_object('ok', false, 'code', 'forbidden', 'message', '承認できるのはマスターだけです'); end if;
  select * into r from sf_attendance_requests where id = p_request_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', 'この申請は見つかりません'); end if;
  if r.status <> 'pending' then
    select name into v_prev from users where id = r.decided_by;
    return jsonb_build_object('ok', false, 'code', 'already', 'message', format('この申請はすでに処理されています（%s・%s）', r.status, coalesce(v_prev, '-')));
  end if;
  if p_approve then
    v_min := round(extract(epoch from (r.clock_out - r.clock_in)) / 60 - r.break_minutes);
    v_duty := round(extract(epoch from (r.clock_out - r.clock_in)) / 60);   -- 2026-11-14: 拘束時間（退勤−出勤）。worked_minutes にはこちらを入れる（v_min＝実労働時間は按分にだけ使う）
    if r.kind = 'fix' then
      select * into l from labor_cost_daily where id = r.labor_cost_daily_id for update;
      if not found then return jsonb_build_object('ok', false, 'code', 'no_record', 'message', '元の勤怠実績が見つかりません（同期で消えた可能性）'); end if;
      -- 2026-11-14: 概算人件費の按分は、実労働時間どうしの比（新しい実労働 ÷ 元の実労働＝元の worked_minutes − 元の休憩）。分母が 0 以下・null なら元の値のまま
      v_est := case when coalesce(l.worked_minutes - coalesce(l.break_minutes, 0), 0) > 0 and l.smaregi_estimate_cost is not null
                    then round(l.smaregi_estimate_cost * v_min / (l.worked_minutes - coalesce(l.break_minutes, 0))) else l.smaregi_estimate_cost end;
      update labor_cost_daily
         set orig_clock_in = coalesce(orig_clock_in, clock_in), orig_clock_out = coalesce(orig_clock_out, clock_out),
             orig_worked_minutes = coalesce(orig_worked_minutes, worked_minutes), orig_smaregi_estimate_cost = coalesce(orig_smaregi_estimate_cost, smaregi_estimate_cost),
             clock_in = r.clock_in, clock_out = r.clock_out, worked_minutes = v_duty, smaregi_estimate_cost = v_est,
             break_start_1 = r.break_start_1, break_end_1 = r.break_end_1, break_start_2 = r.break_start_2, break_end_2 = r.break_end_2, break_minutes = r.break_minutes,
             manual_fixed_at = now(), manual_fixed_by = p_actor, updated_at = now()
       where id = l.id;
      v_new := l.id;
    else
      -- 追加: スマレジ実績 ID は EF の POST 後に入る（それまでは 'req:<申請id>' を仮の一意キーに）。ロック付き＝翌朝の同期で消えない
      insert into labor_cost_daily (user_id, store_id, work_date, clock_in, clock_out, worked_minutes, tardy, early_leaving, smaregi_estimate_cost,
          smaregi_shift_result_id, source, break_start_1, break_end_1, break_start_2, break_end_2, break_minutes, manual_fixed_at, manual_fixed_by)
      values (r.user_id, r.store_id, r.work_date, r.clock_in, r.clock_out, v_duty, false, false, null,
          'req:' || r.id, 'form', r.break_start_1, r.break_end_1, r.break_start_2, r.break_end_2, r.break_minutes, now(), p_actor)
      returning id into v_new;
    end if;
    insert into attendance_records (user_id, store_id, work_date, clock_in, clock_out, source)
      values (r.user_id, r.store_id, r.work_date, r.clock_in, r.clock_out, 'api')   -- source は check (api/csv) のため api
      on conflict (user_id, work_date) do update set clock_in = excluded.clock_in, clock_out = excluded.clock_out;
    update sf_attendance_requests set status = 'approved', labor_cost_daily_id = v_new, decided_by = p_actor, decided_at = now(),
           decision_note = nullif(trim(coalesce(p_note, '')), ''), applied_at = now(), updated_at = now() where id = r.id;
  else
    update sf_attendance_requests set status = 'rejected', decided_by = p_actor, decided_at = now(),
           decision_note = nullif(trim(coalesce(p_note, '')), ''), updated_at = now() where id = r.id;
  end if;
  return jsonb_build_object('ok', true, 'request_id', r.id, 'kind', r.kind, 'approved', p_approve, 'summary', sf_attendance_request_summary(r), 'actor_name', v_name,
    'reason', r.reason, 'requested_by_name', (select name from users where id = r.requested_by), 'requested_by', r.requested_by,
    'approval_notification_ids', to_jsonb(r.approval_notification_ids), 'notice_notification_ids', to_jsonb(r.notice_notification_ids));
end $$;
revoke all on function public.sf_attendance_request_decide(uuid, uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.sf_attendance_request_decide(uuid, uuid, boolean, text, text) to service_role;

-- ============ 3. 休憩の自動補完の反映（代わりの値だけ） ============
create or replace function attendance_break_autofill_finish(p_id uuid, p_status text, p_reason text default null, p_response jsonb default null, p_duty_minute numeric default null, p_cost numeric default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a attendance_break_autofills%rowtype; l labor_cost_daily%rowtype;
begin
  if not onboarding_is_service() then raise exception '権限がありません'; end if;
  if p_status not in ('synced', 'error', 'conflict', 'skipped') then raise exception '不正な状態です'; end if;
  select * into a from attendance_break_autofills where id = p_id for update;
  if a.id is null then raise exception '履歴が見つかりません'; end if;
  if a.status <> 'syncing' then return jsonb_build_object('ok', false, 'reason', 'not_syncing', 'status', a.status); end if;
  if p_status = 'synced' then
    select * into l from labor_cost_daily where id = a.labor_cost_daily_id for update;
    if l.id is null or l.break_start_1 is not null or l.break_end_1 is not null or l.break_start_2 is not null or l.manual_fixed_at is not null
       or l.clock_in is distinct from (a.before ->> 'clock_in')::timestamptz or l.clock_out is distinct from (a.before ->> 'clock_out')::timestamptz then
      -- スマレジには入ったが、そのあいだに管理システム側の勤怠が変わっていた: 管理システムは書き換えない（次の取り込みに任せる）
      update attendance_break_autofills set status = 'conflict', reason = 'hub_changed', smaregi_response = p_response, synced_at = now(), updated_at = now() where id = a.id;
      return jsonb_build_object('ok', true, 'status', 'conflict', 'reason', 'hub_changed');
    end if;
    update labor_cost_daily set break_start_1 = a.est_break_start, break_end_1 = a.est_break_end, break_minutes = a.est_minutes,
           worked_minutes = coalesce(p_duty_minute, worked_minutes), smaregi_estimate_cost = coalesce(p_cost, smaregi_estimate_cost), updated_at = now()
     where id = l.id;
  end if;
  update attendance_break_autofills set status = p_status, reason = p_reason, smaregi_response = p_response, synced_at = case when p_status = 'synced' then now() else synced_at end, updated_at = now() where id = a.id;
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;
revoke all on function attendance_break_autofill_finish(uuid, text, text, jsonb, numeric, numeric) from public, anon, authenticated;
grant execute on function attendance_break_autofill_finish(uuid, text, text, jsonb, numeric, numeric) to service_role;
