-- 採用管理: 採用の決定を、共通の操作にする（Slack の［採用を決める］から、いまの採用の処理 hire_applicant をそのまま呼ぶ）（2026-11-30 下書き）
--   設計: docs/設計書_採用_面接確定とLINEのSlack操作_2026-11-13.md §4 の C7 ／ この段階のメモ: scratchpad ob18/stage3/メモ_第3弾.md
--   ★ 本番未適用（下書き。適用は別途承認）。戻し方: 2026-11-30_recruit_hire_rollback.sql
--   前提: 2026-11-26_recruit_action_base.sql・2026-11-27_recruit_outbox.sql が入っていること
--
--   これを適用しただけでは、いまの動きは何も変わらない。いまの画面の採用（hire_applicant）は、そのまま動く（この SQL は hire_applicant を変えない）。
--   採用の処理そのものは作り直していない: recruit_hire は、確かめ（権限・雇用区分・スイッチ・同じ鍵・古い値）のあと、既存の hire_applicant を「押した人の操作として」呼ぶだけ。
--     hire_applicant は「ログインしている本人」を見る作りなので、呼ぶあいだだけ、この取引の中の「だれの操作か」を、押した人に切り替える（呼び終わったら戻す）。
--   実在の応募者で動くのは、送信のスイッチ（recruit_actions.send_enabled）が true のときだけ。それまでは、テスト用の応募者（answers._test = true）だけ受ける。
--   決まり: アルバイト・パート（form_key = al）＝採用の権限がある担当者／社員（form_key = shain）＝最終決定は社長だけ
--           （マスターを含めるかは設定 recruit_actions.hire_shain_allow_master。既定は、含める）／区分が分からない応募は、ここからは決められない。
--   足すもの: 関数 3 本。 変えないもの: 既存の関数（hire_applicant・create_invite・register_via_invite・onboarding_start など）・トリガー・表。

-- ============ 0. 前提の確認 ============
do $$
begin
  if to_regprocedure('public.hire_applicant(uuid,text,uuid[],integer)') is null or to_regprocedure('public.join_invite_message(uuid,text)') is null then
    raise exception '既存の関数 hire_applicant / join_invite_message がありません';
  end if;
  if to_regclass('public.applicant_ops') is null or to_regprocedure('public.recruit_actions_cfg()') is null or to_regprocedure('public.recruit_kind_of(text)') is null then
    raise exception '先に 2026-11-26_recruit_action_base.sql と 2026-11-27_recruit_outbox.sql を適用してください';
  end if;
end $$;

-- ============ 1. 採用の窓に出す材料と、いま採用にできるかの確かめ（何も書かない） ============
-- 返す形: {"ok": true, "can": true|false, "code": "ok|denied|kind_unknown|employee_ceo_only|disabled|already_hired|not_active|not_found", "message", "name", "kind", "status",
--          "default_role", "roles": [...], "stores": [{"id","name"}], "store_id", "linked", "is_test", "line_mode"}
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

-- ============ 2. 採用を決める（確かめのあと、既存の hire_applicant を、押した人の操作として呼ぶ） ============
-- p_expected: 押した人が見ていた値 {"status": "…"}。いまの状態と違えば、何も変えずに conflict
-- p_invite_base: 招待リンクの土台（例: https://…/nippo/）。入っていれば、招待の文面（既存の join_invite_message）を作って返す（Edge Function が、送信箱を通して LINE で送る）
-- 返す形（code）: done（採用にした。"invite_text"・"linked"）／replayed／noop（すでに採用済み）／conflict／denied／kind_unknown／bad_role／bad_store／disabled／not_active／not_found
--   ★ "invite_text" には招待リンクが入っている。Edge Function の外（Slack・画面への返事）へは出さないこと
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

-- ============ 3. 招待を送った印（いまの画面が、招待の LINE を送ったあとに付けているのと同じ） ============
create or replace function public.recruit_invite_sent(p_applicant uuid, p_actor uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  if not onboarding_is_service() then raise exception '権限がありません（サーバー側の処理だけ）'; end if;
  update applicants set invite_sent_at = now(), last_actor_id = coalesce(p_actor, last_actor_id), last_actor_at = now()
   where id = p_applicant and status = 'hired' and invite_token is not null;
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

-- ============ 4. 権限（どれも、画面からは呼べない。Edge Function＝service_role だけ） ============
revoke all on function public.recruit_hire_info(uuid, uuid), public.recruit_hire(uuid, text, uuid[], text, uuid, text, jsonb, text), public.recruit_invite_sent(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.recruit_hire_info(uuid, uuid), public.recruit_hire(uuid, text, uuid[], text, uuid, text, jsonb, text), public.recruit_invite_sent(uuid, uuid) to service_role;

-- ============ 確認用（読むだけ） ============
-- select op, result, error, count(*) from applicant_ops where op = 'hire' group by 1, 2, 3 order by 1, 2, 3;
