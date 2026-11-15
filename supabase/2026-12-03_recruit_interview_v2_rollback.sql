-- 2026-12-03_recruit_interview_v2.sql を外す  ★実行は別途承認
--   先に、Edge Function（recruit-action）を、変更・取り消しの案内を持たない版に戻すこと（戻さなくても動くが、取り消しの案内の初期値などが合わなくなる）。
--   recruit_interview_begin を、2026-11-28_recruit_interview.sql の中身に戻す。足した設定のキー（interview_minutes・calendar_busy_check）を外す。
--   ※ 戻すと、社員採用の面接の日程調整の既定は「設定が無ければ社長だけ」に戻る（設定 interview_shain_ceo_only が false と入っていれば、任せられるまま）
update app_settings set value = value - 'interview_minutes' - 'calendar_busy_check' where key = 'recruit_actions';

create or replace function public.recruit_interview_begin(
  p_applicant uuid, p_kind text, p_request_key text, p_actor uuid, p_via text,
  p_at timestamptz default null, p_mode text default null, p_place text default null, p_notify boolean default true, p_expected jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_cfg jsonb := recruit_actions_cfg(); v_a record; v_prev applicant_ops%rowtype; v_last applicant_ops%rowtype; v_key text := btrim(coalesce(p_request_key, ''));
  v_op text; v_test boolean; v_place text := nullif(btrim(coalesce(p_place, '')), ''); v_pl jsonb := null; v_before jsonb; v_after jsonb; v_id uuid;
  v_ceo_only boolean; v_event text; v_changed boolean;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  if p_via is null or p_via not in ('slack', 'web', 'app') then raise exception 'p_via が正しくありません'; end if;
  if p_kind is null or p_kind not in ('confirm', 'cancel') then raise exception 'p_kind が正しくありません'; end if;
  if length(v_key) < 8 or length(v_key) > 200 then raise exception '依頼の鍵（p_request_key）が正しくありません'; end if;
  v_op := 'interview_' || p_kind;
  if p_kind = 'confirm' then
    if p_at is null then return jsonb_build_object('ok', false, 'code', 'bad_request', 'message', '面接日時が指定されていません'); end if;
    if p_mode is null or p_mode not in ('online', 'onsite') then return jsonb_build_object('ok', false, 'code', 'bad_request', 'message', '面接のやり方（オンライン／対面）を選んでください'); end if;
    if p_mode = 'onsite' then
      if v_place is null then return jsonb_build_object('ok', false, 'code', 'bad_place', 'message', '面接場所を選んでください'); end if;
      select e into v_pl from app_settings s, jsonb_array_elements(case when jsonb_typeof(s.value) = 'array' then s.value else '[]'::jsonb end) e
       where s.key = 'interview_places' and e ->> 'name' = v_place limit 1;
      if v_pl is null then return jsonb_build_object('ok', false, 'code', 'bad_place', 'message', '面接場所が、設定に見つかりません'); end if;
    else
      v_place := null;
    end if;
  end if;

  -- 応募者の行を押さえる（同じ応募者への操作は、ここで 1 つずつになる）
  select a.id, a.name, a.store_id, a.form_key, a.answers, a.assignee_id, a.line_user_id, a.interview_at, a.interview_mode, a.interview_place, a.interview_url, a.interview_event_id
    into v_a from applicants a where a.id = p_applicant for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;

  -- 「処理中」のまま 2 分を過ぎた行（途中で止まった）は、失敗にする（次の操作をふさがない）
  update applicant_ops set result = 'failed', error = '処理が途中で止まりました' where applicant_id = p_applicant and op in ('interview_confirm', 'interview_cancel')
     and result = 'processing' and created_at < clock_timestamp() - interval '2 minutes';

  -- 同じ依頼の鍵の 2 回目: 何もせず、前の結果を返す
  select * into v_prev from applicant_ops where request_key = v_key;
  if found then
    if v_prev.applicant_id <> p_applicant or v_prev.op <> v_op or v_prev.actor_id is distinct from p_actor then
      return jsonb_build_object('ok', false, 'code', 'key_reused', 'message', '同じ依頼の鍵が、別の操作で使われています');
    end if;
    return jsonb_build_object('ok', v_prev.result in ('done', 'partial', 'noop'), 'code', 'replayed', 'replayed', true, 'op_id', v_prev.id, 'result', v_prev.result, 'steps', v_prev.steps,
      'message', case v_prev.result when 'processing' then '処理中です（もう一度は実行しません）' when 'done' then '処理済みです' when 'partial' then '確定は済んでいます（予定か案内が失敗しています）'
                                   when 'noop' then 'すでにその内容です' when 'conflict' then '先に変更されています' when 'denied' then '権限がありません' else '失敗しています' end);
  end if;

  v_before := jsonb_build_object('interview_at', v_a.interview_at, 'interview_mode', v_a.interview_mode, 'interview_place', v_a.interview_place,
                                 'has_url', coalesce(btrim(coalesce(v_a.interview_url, '')), '') <> '', 'interview_event_id', v_a.interview_event_id, 'assignee_id', v_a.assignee_id);
  v_after := case when p_kind = 'confirm'
                  then jsonb_build_object('interview_at', p_at, 'interview_mode', p_mode, 'interview_place', v_place, 'interview_address', v_pl ->> 'address', 'notify', coalesce(p_notify, true))
                  else jsonb_build_object('interview_at', null) end;

  -- 権限（サーバー側で確かめる）。社員採用は、設定 recruit_actions.interview_shain_ceo_only が false でないかぎり、社長（とマスター）だけ
  if not (coalesce((select u.is_active from users u where u.id = p_actor), false) and has_feature(p_actor, 'recruit') and can_see_applicant(p_actor, v_a.store_id)) then
    v_id := recruit_op_log(p_applicant, v_op, p_actor, p_via, v_key, v_before, v_after, 'denied', 'no_permission', null);
    return jsonb_build_object('ok', false, 'code', 'denied', 'op_id', v_id, 'message', '権限がありません');
  end if;
  v_ceo_only := coalesce((select s.value -> 'interview_shain_ceo_only' <> 'false'::jsonb from app_settings s where s.key = 'recruit_actions'), true);
  if v_a.form_key = 'shain' and v_ceo_only and not coalesce((select u.role = 'CEO' or u.is_master from users u where u.id = p_actor), false) then
    v_id := recruit_op_log(p_applicant, v_op, p_actor, p_via, v_key, v_before, v_after, 'denied', 'employee_ceo_only', null);
    return jsonb_build_object('ok', false, 'code', 'denied', 'op_id', v_id, 'message', '社員採用の面接の確定・取り消しは、社長だけが行えます');
  end if;

  -- スイッチ: 実在の応募者は、送信のスイッチが true、かつ、カレンダーが本番モードのときだけ
  v_test := coalesce(v_a.answers ->> '_test', '') = 'true';
  if not v_test and not ((v_cfg ->> 'send_enabled')::boolean and v_cfg ->> 'calendar_mode' = 'live') then
    return jsonb_build_object('ok', false, 'code', 'disabled', 'message', '面接の確定は、まだここからは使えません（スイッチが OFF、または、カレンダーが試しモードです）。管理画面から操作してください');
  end if;

  -- 同じ応募者の面接の操作が、いま処理中: 何もしない（2 つ同時 → 片方だけ）
  if exists (select 1 from applicant_ops o where o.applicant_id = p_applicant and o.op in ('interview_confirm', 'interview_cancel') and o.result = 'processing') then
    return jsonb_build_object('ok', false, 'code', 'busy', 'message', 'ほかの人が、この応募者の面接を操作しています。少し待って、内容を確かめてください');
  end if;

  -- 古い値の照合: 押した人が見ていた面接日時・担当と、いまの値が違えば、何も変えない
  if p_expected is not null and jsonb_typeof(p_expected) = 'object' then
    if (p_expected ? 'interview_at' and v_a.interview_at is distinct from nullif(p_expected ->> 'interview_at', '')::timestamptz)
       or (p_expected ? 'assignee_id' and v_a.assignee_id::text is distinct from nullif(p_expected ->> 'assignee_id', '')) then
      v_id := recruit_op_log(p_applicant, v_op, p_actor, p_via, v_key, v_before, v_after || jsonb_build_object('expected', p_expected), 'conflict', 'expected_mismatch', null);
      return jsonb_build_object('ok', false, 'code', 'conflict', 'op_id', v_id, 'message', '先に変更されています',
        'current_interview_at', v_a.interview_at, 'current_assignee', v_a.assignee_id, 'current_assignee_name', (select u.name from users u where u.id = v_a.assignee_id));
    end if;
  end if;

  -- すでにその内容
  if (p_kind = 'cancel' and v_a.interview_at is null)
     or (p_kind = 'confirm' and v_a.interview_at = p_at and v_a.interview_mode is not distinct from p_mode
         and (p_mode = 'online' or v_a.interview_place is not distinct from v_place)) then
    v_id := recruit_op_log(p_applicant, v_op, p_actor, p_via, v_key, v_before, v_after, 'noop', null, null);
    return jsonb_build_object('ok', true, 'code', 'noop', 'op_id', v_id,
      'message', case when p_kind = 'cancel' then '面接の日程は、入っていません' else 'すでに、その内容で確定しています' end);
  end if;

  -- いまの予定の番号。無ければ、直前の確定が「予定は作れたが、保存まで行かなかった」ときの番号を使う（やり直しで、予定が 2 つ出来ないように）
  v_event := nullif(btrim(coalesce(v_a.interview_event_id, '')), '');
  if v_event is null then
    select * into v_last from applicant_ops o where o.applicant_id = p_applicant and o.op in ('interview_confirm', 'interview_cancel') and o.result in ('failed', 'partial', 'done')
     order by o.created_at desc, o.id desc limit 1;
    if found and v_last.op = 'interview_confirm' and v_last.steps -> 'calendar' ->> 'mode' = 'live' and v_last.steps -> 'calendar' ->> 'ok' = 'true'
       and coalesce(v_last.steps -> 'save' ->> 'ok', '') <> 'true' then
      v_event := nullif(v_last.steps -> 'calendar' ->> 'event_id', '');
    end if;
  end if;
  v_changed := p_kind = 'confirm' and v_event is not null and v_a.interview_mode is not null and v_a.interview_mode <> p_mode;

  insert into applicant_ops (applicant_id, op, actor_id, via, request_key, before_state, after_state, result, created_at)
  values (p_applicant, v_op, p_actor, p_via, v_key, v_before, v_after, 'processing', clock_timestamp())
  returning id into v_id;

  return jsonb_build_object('ok', true, 'code', 'go', 'op_id', v_id, 'kind', p_kind, 'is_test', v_test,
    'calendar_mode', v_cfg ->> 'calendar_mode', 'line_mode', v_cfg ->> 'line_mode',
    'applicant_name', v_a.name, 'linked', coalesce(btrim(coalesce(v_a.line_user_id, '')), '') <> '',
    'event_id', v_event, 'mode_changed', v_changed, 'current_url', v_a.interview_url,
    'interviewer_name', (select u.name from users u where u.id = v_a.assignee_id), 'actor_name', (select u.name from users u where u.id = p_actor),
    'at', p_at, 'mode', p_mode, 'place', v_place, 'address', v_pl ->> 'address', 'place_note', v_pl ->> 'note', 'notify', coalesce(p_notify, true));
end $$;
