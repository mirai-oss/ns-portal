-- 採用管理: 面接の確定・変更・取り消しを、サーバー側の共通の操作にする（2026-11-28 下書き）
--   設計: docs/設計書_採用_面接確定とLINEのSlack操作_2026-11-13.md §2.3 ／ この段階のメモ: scratchpad ob18/stage2/メモ_第2弾.md
--   ★ 本番未適用（下書き。適用は別途承認）。戻し方: 2026-11-28_recruit_interview_rollback.sql
--   前提: 2026-11-26_recruit_action_base.sql と 2026-11-27_recruit_outbox.sql が入っていること
--
--   これを適用しただけでは、いまの動きは何も変わらない。いまの画面の確定（set_interview）は、そのまま動く（この SQL は set_interview を変えない・呼ばない）。
--   この中に、カレンダー（GAS）・LINE・Slack を呼ぶ処理は無い（呼ぶのは Edge Function recruit-action。ここは「始めてよいか」「保存」「段ごとの結果の記録」だけ）。
--   実在の応募者で動くのは、送信のスイッチ（recruit_actions.send_enabled）が true、かつ、カレンダーが本番モード（calendar_mode = live）のときだけ。
--     それ以外のあいだは、テスト用の応募者（answers._test = true）だけ受ける（テスト用の応募者では、管理システム内のお知らせ＝Chatwork などへ流れる通知も作らない）。
--   足すもの: applicant_ops に列 1 つ（steps）と、結果の値 2 つ（processing・partial）／関数 5 本。 変えないもの: 既存の関数・トリガー・表の列（applicants など）。

-- ============ 0. 前提の確認 ============
do $$
begin
  if to_regclass('public.applicant_ops') is null or to_regclass('public.applicant_outbox') is null or to_regprocedure('public.recruit_actions_cfg()') is null then
    raise exception '先に 2026-11-26_recruit_action_base.sql と 2026-11-27_recruit_outbox.sql を適用してください';
  end if;
  if (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'applicants'
       and column_name in ('interview_at', 'interview_url', 'interview_mode', 'interview_place', 'interview_address', 'interview_set_by', 'interview_event_id', 'interview_sent_at')) <> 8 then
    raise exception 'applicants に、面接の列が足りません';
  end if;
end $$;

-- ============ 1. 操作の記録に、段ごとの結果を持たせる ============
-- steps＝段ごとの結果（calendar＝予定・Meet／save＝確定の保存／notice＝応募者への案内）。result に processing（処理中）と partial（確定は済んだが、予定か案内が失敗）を足す
alter table public.applicant_ops add column if not exists steps jsonb not null default '{}'::jsonb;
alter table public.applicant_ops drop constraint if exists applicant_ops_result_check;
alter table public.applicant_ops add constraint applicant_ops_result_check
  check (result in ('done', 'noop', 'conflict', 'denied', 'failed', 'processing', 'partial'));

-- ============ 2. 始まり（権限・スイッチ・同じ鍵・同時の操作・古い値の照合を確かめて、「処理中」の 1 行を入れる） ============
-- p_kind: confirm（確定・変更）／cancel（取り消し）
-- p_expected: 押した人が見ていた値 {"interview_at": "<日時>" | null, "assignee_id": "<uuid>" | null}。入っているキーだけ、いまの値と比べる。違えば、何も変えずに conflict
-- 返す形（code）:
--   go       … 進めてよい。"op_id" と、予定・案内に要る材料（応募者の氏名・いまの予定の番号・面接担当の氏名・場所の住所と注意書き・LINE と連携しているか・モード）を返す
--   replayed … 同じ依頼の鍵の 2 回目（前の結果を返すだけ）／busy … 同じ応募者の面接の操作が、いま処理中／noop … すでにその内容
--   conflict / denied / disabled / not_found / bad_place … 何も変えない（"message" に理由）
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

-- ============ 3. 段の結果を控える（処理中の行にだけ） ============
create or replace function public.recruit_interview_step(p_op uuid, p_step text, p_data jsonb)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_step is null or p_step not in ('calendar', 'save', 'notice') then raise exception 'p_step が正しくありません'; end if;
  update applicant_ops set steps = steps || jsonb_build_object(p_step, coalesce(p_data, '{}'::jsonb))
   where id = p_op and result = 'processing' and op in ('interview_confirm', 'interview_cancel');
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

-- ============ 4. 保存（確定・変更＝いまの画面の set_interview と同じ書き込み＋予定の番号／取り消し＝いまの画面の「取り消す」と同じ書き込み） ============
-- p_url: 発行できた面接 URL（null・空なら、いまの URL のまま＝ set_interview と同じ）
-- p_event_id: 予定の番号（null なら変えない）／p_event_clear: 予定の番号を空にする（方法を変えて古い予定を消したのに、新しい予定が作れなかったとき）
create or replace function public.recruit_interview_save(p_op uuid, p_url text default null, p_event_id text default null, p_event_clear boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_o applicant_ops%rowtype; v_a record; v_at timestamptz; v_mode text; v_place text; v_addr text; v_url text; v_test boolean;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  select * into v_o from applicant_ops where id = p_op for update;
  if not found or v_o.result <> 'processing' or v_o.op not in ('interview_confirm', 'interview_cancel') then
    return jsonb_build_object('ok', false, 'code', 'not_processing', 'message', '処理中の操作ではありません');
  end if;
  select a.id, a.name, a.store_id, a.answers into v_a from applicants a where a.id = v_o.applicant_id for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;

  if v_o.op = 'interview_cancel' then
    -- いまの画面の「面接日時を取り消す」と同じ: 日時・URL・予定の番号・案内を送った印を空に（状態・方法・場所・確定した人は、今までどおり変えない）
    update applicants set interview_at = null, interview_url = null, interview_event_id = null, interview_sent_at = null,
           updated_at = now(), last_actor_id = v_o.actor_id, last_actor_at = now()
     where id = v_o.applicant_id;
    update applicant_ops set steps = steps || '{"save": {"ok": true}}'::jsonb where id = p_op;
    return jsonb_build_object('ok', true, 'code', 'saved', 'kind', 'cancel');
  end if;

  v_at := (v_o.after_state ->> 'interview_at')::timestamptz; v_mode := v_o.after_state ->> 'interview_mode';
  v_place := v_o.after_state ->> 'interview_place'; v_addr := v_o.after_state ->> 'interview_address';
  if v_at is null or v_mode is null then return jsonb_build_object('ok', false, 'code', 'bad_op', 'message', '操作の中身が読めません'); end if;
  -- いまの画面の set_interview（引数 6 つ）と同じ書き込み。違いは、操作者を引数の記録から取ることと、予定の番号を同じ 1 回で入れること
  update applicants set
    interview_at = v_at,
    interview_url = coalesce(nullif(btrim(coalesce(p_url, '')), ''), interview_url),
    interview_mode = coalesce(v_mode, interview_mode),
    interview_place = coalesce(nullif(btrim(coalesce(v_place, '')), ''), interview_place),
    interview_address = coalesce(nullif(btrim(coalesce(v_addr, '')), ''), interview_address),
    interview_event_id = case when nullif(btrim(coalesce(p_event_id, '')), '') is not null then btrim(p_event_id)
                              when coalesce(p_event_clear, false) then null else interview_event_id end,
    interview_set_by = v_o.actor_id,
    status = case when status in ('new', 'contacted') then 'interview_set' else status end,
    status_changed_at = case when status in ('new', 'contacted') then now() else status_changed_at end,
    last_actor_id = v_o.actor_id, last_actor_at = now(),
    updated_at = now()
   where id = v_o.applicant_id
   returning interview_url into v_url;

  -- 管理システム内のお知らせ（set_interview と同じ文面・同じ宛先）。テスト用の応募者では作らない（実在の担当者に、テストの知らせを流さないため）
  v_test := coalesce(v_a.answers ->> '_test', '') = 'true';
  if not v_test then
    insert into notifications (recipient_id, actor_id, type, body_i18n, link)
    select u.id, v_o.actor_id, 'applicant_new',
           jsonb_build_object('ja', '面接日時が決まりました: ' || v_a.name || 'さん　'
             || to_char(v_at at time zone 'Asia/Tokyo', 'MM/DD(Dy) HH24:MI')
             || case when v_mode = 'onsite' then E'\n対面: ' || coalesce(v_place, '（場所未設定）')
                     when coalesce(btrim(coalesce(v_url, '')), '') <> '' then E'\nオンライン: ' || v_url
                     else '' end),
           jsonb_build_object('applicant_id', v_o.applicant_id)
      from users u
     where u.is_active and u.id is distinct from v_o.actor_id and can_see_applicant(u.id, v_a.store_id);
  end if;

  update applicant_ops set steps = steps || '{"save": {"ok": true}}'::jsonb where id = p_op;
  return jsonb_build_object('ok', true, 'code', 'saved', 'kind', 'confirm', 'applicant_name', v_a.name, 'interview_at', v_at, 'interview_mode', v_mode,
    'interview_place', v_place, 'interview_address', v_addr, 'interview_url', v_url);
end $$;

-- ============ 5. 終わり（結果を入れる。done＝全部済んだ／partial＝確定は済んだが、予定か案内が失敗／failed＝確定できなかった） ============
create or replace function public.recruit_interview_finish(p_op uuid, p_result text, p_error text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_result is null or p_result not in ('done', 'partial', 'failed') then raise exception 'p_result が正しくありません'; end if;
  update applicant_ops set result = p_result, error = nullif(left(coalesce(p_error, ''), 500), '')
   where id = p_op and result = 'processing' and op in ('interview_confirm', 'interview_cancel');
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n = 1, 'code', case when v_n = 1 then p_result else 'not_processing' end);
end $$;

-- ============ 6. 権限（どれも、画面からは呼べない。Edge Function＝service_role だけ） ============
revoke all on function public.recruit_interview_begin(uuid, text, text, uuid, text, timestamptz, text, text, boolean, jsonb),
  public.recruit_interview_step(uuid, text, jsonb), public.recruit_interview_save(uuid, text, text, boolean), public.recruit_interview_finish(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.recruit_interview_begin(uuid, text, text, uuid, text, timestamptz, text, text, boolean, jsonb),
  public.recruit_interview_step(uuid, text, jsonb), public.recruit_interview_save(uuid, text, text, boolean), public.recruit_interview_finish(uuid, text, text)
  to service_role;

-- ============ 確認用（読むだけ） ============
-- select op, result, count(*) from applicant_ops where op like 'interview_%' group by 1, 2 order by 1, 2;
-- select id, result, steps, error, created_at from applicant_ops where op like 'interview_%' and result in ('partial', 'failed') order by created_at desc limit 20;
