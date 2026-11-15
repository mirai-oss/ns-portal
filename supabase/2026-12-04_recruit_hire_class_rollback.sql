-- 2026-12-04_recruit_hire_class.sql を外す  ★実行は別途承認
--   先に、Edge Function（recruit-action・slack-interact）と画面（nippo）を、雇用区分を渡さない版に戻すこと。
--   列 invitations.employment_class は、値が入っている行があれば残す（消すと、控えた雇用区分が無くなるため）。
drop function if exists public.recruit_employment_hint(uuid);
drop function if exists public.recruit_invite_class_set(uuid, text);
drop function if exists public.recruit_hire(uuid, text, uuid[], text, uuid, text, jsonb, text, text);

-- recruit_hire_info・recruit_hire を、2026-11-30_recruit_hire.sql の中身に戻す
create or replace function public.recruit_hire_info(p_applicant uuid, p_actor uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_cfg jsonb := recruit_actions_cfg(); v_a record; v_kind text; v_test boolean; v_code text := 'ok'; v_msg text := null; v_allow_master boolean; v_top boolean;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  select a.id, a.name, a.store_id, a.form_key, a.answers, a.status, a.line_user_id into v_a from applicants a where a.id = p_applicant;
  if not found then return jsonb_build_object('ok', false, 'can', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;
  if not (coalesce((select u.is_active from users u where u.id = p_actor), false) and has_feature(p_actor, 'recruit') and can_see_applicant(p_actor, v_a.store_id)) then
    return jsonb_build_object('ok', false, 'can', false, 'code', 'denied', 'message', '権限がありません');
  end if;
  v_kind := recruit_kind_of(v_a.form_key);
  v_test := coalesce(v_a.answers ->> '_test', '') = 'true';
  v_allow_master := coalesce((select s.value -> 'hire_shain_allow_master' <> 'false'::jsonb from app_settings s where s.key = 'recruit_actions'), true);
  v_top := coalesce((select u.role = 'CEO' or (v_allow_master and coalesce(u.is_master, false)) from users u where u.id = p_actor), false);
  if v_a.status = 'hired' then v_code := 'already_hired'; v_msg := 'すでに採用済みです（招待の再発行は、管理画面から行ってください）';
  elsif v_a.status not in ('new', 'contacted', 'interview_set', 'interviewed') then v_code := 'not_active'; v_msg := '選考中の応募者ではありません（状態を、管理画面で確かめてください）';
  elsif v_kind = 'unknown' then v_code := 'kind_unknown'; v_msg := '雇用区分（アルバイト／社員）が決まっていません。管理画面で、区分を先に決めてください';
  elsif v_kind = 'employee' and not v_top then v_code := 'employee_ceo_only'; v_msg := '社員採用の最終決定は、社長だけが行えます';
  elsif not (v_cfg ->> 'send_enabled')::boolean and not v_test then v_code := 'disabled'; v_msg := '採用の決定は、まだここからは使えません（スイッチが OFF です）。管理画面から操作してください';
  end if;
  return jsonb_build_object('ok', true, 'can', v_code = 'ok', 'code', v_code, 'message', v_msg, 'name', v_a.name, 'kind', v_kind, 'status', v_a.status,
    'default_role', case v_kind when 'part' then 'AL' when 'employee' then 'SHAIN' else null end,
    'roles', case v_kind when 'part' then '["AL"]'::jsonb when 'employee' then '["SHAIN", "TENCHO", "TEAM", "HQ"]'::jsonb else '[]'::jsonb end,
    'stores', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.sort_order, s.name) from stores s where s.is_active), '[]'::jsonb),
    'store_id', v_a.store_id, 'linked', coalesce(btrim(coalesce(v_a.line_user_id, '')), '') <> '', 'is_test', v_test, 'line_mode', v_cfg ->> 'line_mode');
end $$;

create or replace function public.recruit_hire(
  p_applicant uuid, p_role text, p_store_ids uuid[], p_request_key text, p_actor uuid, p_via text, p_expected jsonb default null, p_invite_base text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := recruit_actions_cfg(); v_a record; v_prev applicant_ops%rowtype; v_key text := btrim(coalesce(p_request_key, '')); v_kind text; v_test boolean;
  v_allow_master boolean; v_top boolean; v_before jsonb; v_after jsonb; v_id uuid; v_token text; v_text text := null; v_inv uuid;
  v_old_claims text; v_old_sub text; v_stores uuid[] := coalesce(p_store_ids, '{}'::uuid[]); v_base text := nullif(btrim(coalesce(p_invite_base, '')), '');
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  if p_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  if p_via is null or p_via not in ('slack', 'web', 'app') then raise exception 'p_via が正しくありません'; end if;
  if length(v_key) < 8 or length(v_key) > 200 then raise exception '依頼の鍵（p_request_key）が正しくありません'; end if;

  -- 応募者の行を押さえる（2 つ同時 → 1 つずつ。あとの人は「すでに採用済み」になる）
  select a.id, a.name, a.store_id, a.form_key, a.answers, a.status, a.line_user_id into v_a from applicants a where a.id = p_applicant for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;

  -- 同じ依頼の鍵の 2 回目: 何もせず、前の結果を返す（招待の文面は返さない＝もう一度は送らない）
  select * into v_prev from applicant_ops where request_key = v_key;
  if found then
    if v_prev.applicant_id <> p_applicant or v_prev.op <> 'hire' or v_prev.actor_id is distinct from p_actor then
      return jsonb_build_object('ok', false, 'code', 'key_reused', 'message', '同じ依頼の鍵が、別の操作で使われています');
    end if;
    return jsonb_build_object('ok', v_prev.result in ('done', 'noop'), 'code', 'replayed', 'replayed', true, 'op_id', v_prev.id, 'result', v_prev.result,
      'message', case v_prev.result when 'done' then '採用の決定は、処理済みです' when 'noop' then 'すでに採用済みです' when 'conflict' then '先に変更されています' when 'denied' then '権限がありません' else '採用にできていません' end);
  end if;

  v_before := jsonb_build_object('status', v_a.status);
  v_after := jsonb_build_object('status', 'hired', 'role', p_role, 'store_ids', to_jsonb(v_stores));

  -- 権限（サーバー側で確かめる）
  if not (coalesce((select u.is_active from users u where u.id = p_actor), false) and has_feature(p_actor, 'recruit') and can_see_applicant(p_actor, v_a.store_id)) then
    v_id := recruit_op_log(p_applicant, 'hire', p_actor, p_via, v_key, v_before, v_after, 'denied', 'no_permission', null);
    return jsonb_build_object('ok', false, 'code', 'denied', 'op_id', v_id, 'message', '権限がありません');
  end if;
  -- 状態: 選考中の応募者だけ（すでに採用済みなら、何もしない）
  if v_a.status = 'hired' then
    v_id := recruit_op_log(p_applicant, 'hire', p_actor, p_via, v_key, v_before, v_after, 'noop', null, null);
    return jsonb_build_object('ok', true, 'code', 'noop', 'op_id', v_id, 'message', 'すでに採用済みです（招待の再発行は、管理画面から行ってください）');
  end if;
  if v_a.status not in ('new', 'contacted', 'interview_set', 'interviewed') then
    return jsonb_build_object('ok', false, 'code', 'not_active', 'message', '選考中の応募者ではありません（状態を、管理画面で確かめてください）');
  end if;
  -- 雇用区分: 分からない応募は、ここからは決められない。役割は、区分に合うものだけ（区分と違う役割で、社員採用の決まりをすり抜けられないように）
  v_kind := recruit_kind_of(v_a.form_key);
  if v_kind = 'unknown' then
    return jsonb_build_object('ok', false, 'code', 'kind_unknown', 'message', '雇用区分（アルバイト／社員）が決まっていません。管理画面で、区分を先に決めてください');
  end if;
  if p_role is null or (v_kind = 'part' and p_role <> 'AL') or (v_kind = 'employee' and p_role not in ('SHAIN', 'TENCHO', 'TEAM', 'HQ')) then
    return jsonb_build_object('ok', false, 'code', 'bad_role', 'message', '役割が、雇用区分と合っていません（アルバイト・パート＝アルバイト／社員＝社員・店長・チーム長・本部）');
  end if;
  -- 社員採用の最終決定は、社長だけ（マスターを含めるかは設定。既定は含める）
  v_allow_master := coalesce((select s.value -> 'hire_shain_allow_master' <> 'false'::jsonb from app_settings s where s.key = 'recruit_actions'), true);
  v_top := coalesce((select u.role = 'CEO' or (v_allow_master and coalesce(u.is_master, false)) from users u where u.id = p_actor), false);
  if v_kind = 'employee' and not v_top then
    v_id := recruit_op_log(p_applicant, 'hire', p_actor, p_via, v_key, v_before, v_after, 'denied', 'employee_ceo_only', null);
    return jsonb_build_object('ok', false, 'code', 'denied', 'op_id', v_id, 'message', '社員採用の最終決定は、社長だけが行えます');
  end if;
  -- スイッチ: 閉じているあいだは、テスト用の印の付いた応募者だけ
  v_test := coalesce(v_a.answers ->> '_test', '') = 'true';
  if not (v_cfg ->> 'send_enabled')::boolean and not v_test then
    return jsonb_build_object('ok', false, 'code', 'disabled', 'message', '採用の決定は、まだここからは使えません（スイッチが OFF です）。管理画面から操作してください');
  end if;
  -- 所属店舗: 1 つ以上・有効な店舗だけ
  if cardinality(v_stores) = 0 or (select count(*) from stores s where s.id = any(v_stores) and s.is_active) <> (select count(distinct x) from unnest(v_stores) x) then
    return jsonb_build_object('ok', false, 'code', 'bad_store', 'message', '所属店舗を、1 つ以上選んでください（有効な店舗だけ）');
  end if;
  -- 古い値の照合: 押した人が見ていた状態と、いまの状態が違えば、何も変えない
  if p_expected is not null and jsonb_typeof(p_expected) = 'object' and p_expected ? 'status' and v_a.status is distinct from (p_expected ->> 'status') then
    v_id := recruit_op_log(p_applicant, 'hire', p_actor, p_via, v_key, v_before, v_after || jsonb_build_object('expected', p_expected), 'conflict', 'expected_mismatch', null);
    return jsonb_build_object('ok', false, 'code', 'conflict', 'op_id', v_id, 'message', '先に変更されています', 'current_status', v_a.status);
  end if;

  -- 既存の採用の処理を、押した人の操作として呼ぶ（呼ぶあいだだけ「だれの操作か」を切り替え、終わったら戻す。失敗したら、戻してから同じエラーを上げる）
  v_old_claims := current_setting('request.jwt.claims', true);
  v_old_sub := current_setting('request.jwt.claim.sub', true);
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', p_actor, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', p_actor::text, true);
    v_token := hire_applicant(p_applicant, p_role, v_stores);
    perform set_config('request.jwt.claims', coalesce(v_old_claims, ''), true);
    perform set_config('request.jwt.claim.sub', coalesce(v_old_sub, ''), true);
  exception when others then
    perform set_config('request.jwt.claims', coalesce(v_old_claims, ''), true);
    perform set_config('request.jwt.claim.sub', coalesce(v_old_sub, ''), true);
    raise;
  end;
  if v_token is null then raise exception '採用の処理が、招待を返しませんでした'; end if;
  -- だれが採用にしたかを、応募者の行にも残す（Slack のスレッドの「操作: ○○」に出る。いまの画面の採用との違いは、ここだけ）
  update applicants set last_actor_id = p_actor, last_actor_at = now() where id = p_applicant;
  select i.id into v_inv from invitations i where i.token = v_token;
  v_id := recruit_op_log(p_applicant, 'hire', p_actor, p_via, v_key, v_before, v_after || jsonb_build_object('invitation_id', v_inv), 'done', null, null);
  if v_base is not null then v_text := join_invite_message(p_applicant, v_base || '?invite=' || v_token); end if;
  return jsonb_build_object('ok', true, 'code', 'done', 'op_id', v_id, 'applicant_name', v_a.name, 'actor_name', (select u.name from users u where u.id = p_actor),
    'role', p_role, 'kind', v_kind, 'linked', coalesce(btrim(coalesce(v_a.line_user_id, '')), '') <> '', 'is_test', v_test, 'invite_text', v_text);
end $$;

revoke all on function public.recruit_hire_info(uuid, uuid), public.recruit_hire(uuid, text, uuid[], text, uuid, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.recruit_hire_info(uuid, uuid), public.recruit_hire(uuid, text, uuid[], text, uuid, text, jsonb, text) to service_role;

do $$
begin
  if exists (select 1 from public.invitations where employment_class is not null) then
    raise notice '招待に雇用区分の控えがあるため、列 invitations.employment_class は残しました';
  else
    alter table public.invitations drop constraint if exists invitations_employment_class_check;
    alter table public.invitations drop column if exists employment_class;
  end if;
end $$;
