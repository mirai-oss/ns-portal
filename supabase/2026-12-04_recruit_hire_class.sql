-- 採用管理: 採用のときの「雇用区分」を、役割とは別の項目として持つ／社員採用の最終決定は社長だけ（マスターを含めない）を既定に／画面からの採用でも同じ口を使えるように（2026-12-04 下書き）
--   社長の指示（アルバイト・パート応募＝アルバイト／パート・社員応募＝社員／店長／チーム長／本部。役職と雇用区分は別項目で。マスター権限には、通常の社員採用の決裁権限を付けない）への対応。
--   ★ 本番未適用（下書き。適用は別途承認）。戻し方: 2026-12-04_recruit_hire_class_rollback.sql
--   前提: 採用の SQL（2026-11-26〜2026-11-30）が入っていること（適用済みのファイルは編集しない）
--
--   調べた事実: 「パート」を表す役割も、雇用区分を持つ列も、いまは無い（users.role は AL・SHAIN・TENCHO・TEAM・HQ・CEO。雇用区分があるのは、賃金の承認の記録 onboarding_wage_requests.employment_class〈part／regular〉だけ）。
--   足すもの: 列 1 つ（invitations.employment_class）・関数 2 本（画面用の口・賃金の承認へ渡す口）。 作り直すもの: recruit_hire_info・recruit_hire（自分たちの第 3 弾の関数。引数を 1 つ足す）。
--   recruit_hire は、管理システムの画面（ログインしている本人）からも呼べるようにする（Slack と画面で、同じ採用の決定の処理を使うため）。
--     画面からのときは、Slack 用のスイッチ（send_enabled）では閉じない（画面からの採用は、今までどおりの通常の操作）。権限・雇用区分・社員採用は社長だけ、は画面からでも同じに確かめる。
--   変えないもの: 既存の採用の処理 hire_applicant・入社登録（register_via_invite・onboarding_start）・賃金の承認の判定（onboarding_wage_rule）。
--     賃金の承認の判定は、別の担当が触る予定のため、ここでは「引き継ぎの口」（recruit_employment_hint）を作るところまで。判定の側に要る変更は、メモに書いた。
--   これを適用しただけでは、外へは何も出ない。Slack の採用のボタン・送信のスイッチの決まりは、そのまま。

-- ============ 0. 前提の確認 ============
do $$
begin
  if to_regprocedure('public.recruit_hire(uuid,text,uuid[],text,uuid,text,jsonb,text)') is null and to_regprocedure('public.recruit_hire(uuid,text,uuid[],text,uuid,text,jsonb,text,text)') is null then
    raise exception '先に 2026-11-30_recruit_hire.sql を適用してください';
  end if;
  if to_regclass('public.invitations') is null then raise exception '表 invitations がありません'; end if;
end $$;

-- ============ 1. 招待に、雇用区分を控える列（役割 role とは別の項目。null＝決めていない＝今までの招待） ============
--   arbeit＝アルバイト／part＝パート／regular＝正社員
alter table public.invitations add column if not exists employment_class text;
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'public.invitations'::regclass and conname = 'invitations_employment_class_check') then
    alter table public.invitations add constraint invitations_employment_class_check check (employment_class is null or employment_class in ('arbeit', 'part', 'regular'));
  end if;
end $$;

-- 設定: 社員採用の最終決定にマスターを含めるか（既定 false＝社長だけ）。無いキーだけ足す（いまの値は変えない）
update app_settings set value = '{"hire_shain_allow_master": false}'::jsonb || value where key = 'recruit_actions';

-- ============ 2. 採用の窓の材料（作り直し。引数は同じ。雇用区分の選択肢を足す・マスターの既定を変える） ============
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
  v_allow_master := coalesce((select s.value -> 'hire_shain_allow_master' = 'true'::jsonb from app_settings s where s.key = 'recruit_actions'), false);   -- 2026-12-04: 既定は「社長だけ」（マスターは、設定がはっきり true のときだけ含める）
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
    'store_id', v_a.store_id, 'linked', coalesce(btrim(coalesce(v_a.line_user_id, '')), '') <> '', 'is_test', v_test, 'line_mode', v_cfg ->> 'line_mode',
    -- 2026-12-04: 雇用区分（役割とは別の項目）。アルバイト・パートの応募＝アルバイト／パートから選ぶ。社員の応募＝正社員
    'classes', case v_kind when 'part' then '["arbeit", "part"]'::jsonb when 'employee' then '["regular"]'::jsonb else '[]'::jsonb end,
    'default_class', case v_kind when 'part' then 'arbeit' when 'employee' then 'regular' else null end);
end $$;

-- ============ 3. 採用を決める（作り直し。引数を 1 つ足す: p_employment_class。前の形の関数は、先に消す＝同じ名前が 2 つにならないように） ============
drop function if exists public.recruit_hire(uuid, text, uuid[], text, uuid, text, jsonb, text);
create or replace function public.recruit_hire(
  p_applicant uuid, p_role text, p_store_ids uuid[], p_request_key text, p_actor uuid, p_via text, p_expected jsonb default null, p_invite_base text default null, p_employment_class text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_cfg jsonb := recruit_actions_cfg(); v_a record; v_prev applicant_ops%rowtype; v_key text := btrim(coalesce(p_request_key, '')); v_kind text; v_test boolean;
  v_allow_master boolean; v_top boolean; v_before jsonb; v_after jsonb; v_id uuid; v_token text; v_text text := null; v_inv uuid;
  v_old_claims text; v_old_sub text; v_stores uuid[] := coalesce(p_store_ids, '{}'::uuid[]); v_base text := nullif(btrim(coalesce(p_invite_base, '')), ''); v_class text; v_actor uuid; v_via text;
begin
  -- 2026-12-04: 管理システムの画面（ログインしている本人）からも呼べる＝ Slack と画面で、同じ採用の決定の処理を使う。
  --   本人のときは、操作者＝本人・入口＝web（引数の p_actor・p_via は見ない）。Edge Function（service_role）のときは、引数のとおり
  if auth.uid() is not null then v_actor := auth.uid(); v_via := 'web';
  elsif onboarding_is_service() then v_actor := p_actor; v_via := p_via;
  else raise exception '認証が必要です';
  end if;
  if v_actor is null then raise exception '操作する人（p_actor）が指定されていません'; end if;
  if v_via is null or v_via not in ('slack', 'web', 'app') then raise exception 'p_via が正しくありません'; end if;
  if length(v_key) < 8 or length(v_key) > 200 then raise exception '依頼の鍵（p_request_key）が正しくありません'; end if;

  -- 応募者の行を押さえる（2 つ同時 → 1 つずつ。あとの人は「すでに採用済み」になる）
  select a.id, a.name, a.store_id, a.form_key, a.answers, a.status, a.line_user_id into v_a from applicants a where a.id = p_applicant for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;

  -- 同じ依頼の鍵の 2 回目: 何もせず、前の結果を返す（招待の文面は返さない＝もう一度は送らない）
  select * into v_prev from applicant_ops where request_key = v_key;
  if found then
    if v_prev.applicant_id <> p_applicant or v_prev.op <> 'hire' or v_prev.actor_id is distinct from v_actor then
      return jsonb_build_object('ok', false, 'code', 'key_reused', 'message', '同じ依頼の鍵が、別の操作で使われています');
    end if;
    return jsonb_build_object('ok', v_prev.result in ('done', 'noop'), 'code', 'replayed', 'replayed', true, 'op_id', v_prev.id, 'result', v_prev.result,
      'message', case v_prev.result when 'done' then '採用の決定は、処理済みです' when 'noop' then 'すでに採用済みです' when 'conflict' then '先に変更されています' when 'denied' then '権限がありません' else '採用にできていません' end);
  end if;

  v_before := jsonb_build_object('status', v_a.status);
  v_after := jsonb_build_object('status', 'hired', 'role', p_role, 'store_ids', to_jsonb(v_stores));

  -- 権限（サーバー側で確かめる）
  if not (coalesce((select u.is_active from users u where u.id = v_actor), false) and has_feature(v_actor, 'recruit') and can_see_applicant(v_actor, v_a.store_id)) then
    v_id := recruit_op_log(p_applicant, 'hire', v_actor, v_via, v_key, v_before, v_after, 'denied', 'no_permission', null);
    return jsonb_build_object('ok', false, 'code', 'denied', 'op_id', v_id, 'message', '権限がありません');
  end if;
  -- 状態: 選考中の応募者だけ（すでに採用済みなら、何もしない）
  if v_a.status = 'hired' then
    v_id := recruit_op_log(p_applicant, 'hire', v_actor, v_via, v_key, v_before, v_after, 'noop', null, null);
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
  -- 2026-12-04 雇用区分（役割とは別の項目）: アルバイト・パートの応募＝アルバイト（arbeit）か パート（part）／社員の応募＝正社員（regular）。指定が無ければ、アルバイト／正社員
  v_class := coalesce(nullif(btrim(coalesce(p_employment_class, '')), ''), case when v_kind = 'part' then 'arbeit' else 'regular' end);
  if (v_kind = 'part' and v_class not in ('arbeit', 'part')) or (v_kind = 'employee' and v_class <> 'regular') then
    return jsonb_build_object('ok', false, 'code', 'bad_class', 'message', '雇用区分が、応募の区分と合っていません（アルバイト・パートの応募＝アルバイト／パート・社員の応募＝正社員）');
  end if;
  -- 社員採用の最終決定は、社長だけ（マスターを含めるかは設定。既定は含める）
  v_allow_master := coalesce((select s.value -> 'hire_shain_allow_master' = 'true'::jsonb from app_settings s where s.key = 'recruit_actions'), false);   -- 2026-12-04: 既定は「社長だけ」（マスターは、設定がはっきり true のときだけ含める）
  v_top := coalesce((select u.role = 'CEO' or (v_allow_master and coalesce(u.is_master, false)) from users u where u.id = v_actor), false);
  if v_kind = 'employee' and not v_top then
    v_id := recruit_op_log(p_applicant, 'hire', v_actor, v_via, v_key, v_before, v_after, 'denied', 'employee_ceo_only', null);
    return jsonb_build_object('ok', false, 'code', 'denied', 'op_id', v_id, 'message', '社員採用の最終決定は、社長だけが行えます');
  end if;
  -- スイッチ: 閉じているあいだは、テスト用の印の付いた応募者だけ
  v_test := coalesce(v_a.answers ->> '_test', '') = 'true';
  -- 2026-12-04: スイッチで閉じるのは、画面以外（Slack など）からの操作だけ。画面からの採用は、今までどおりの通常の操作なので、閉じない
  if v_via <> 'web' and not (v_cfg ->> 'send_enabled')::boolean and not v_test then
    return jsonb_build_object('ok', false, 'code', 'disabled', 'message', '採用の決定は、まだここからは使えません（スイッチが OFF です）。管理画面から操作してください');
  end if;
  -- 所属店舗: 1 つ以上・有効な店舗だけ
  if cardinality(v_stores) = 0 or (select count(*) from stores s where s.id = any(v_stores) and s.is_active) <> (select count(distinct x) from unnest(v_stores) x) then
    return jsonb_build_object('ok', false, 'code', 'bad_store', 'message', '所属店舗を、1 つ以上選んでください（有効な店舗だけ）');
  end if;
  -- 古い値の照合: 押した人が見ていた状態と、いまの状態が違えば、何も変えない
  if p_expected is not null and jsonb_typeof(p_expected) = 'object' and p_expected ? 'status' and v_a.status is distinct from (p_expected ->> 'status') then
    v_id := recruit_op_log(p_applicant, 'hire', v_actor, v_via, v_key, v_before, v_after || jsonb_build_object('expected', p_expected), 'conflict', 'expected_mismatch', null);
    return jsonb_build_object('ok', false, 'code', 'conflict', 'op_id', v_id, 'message', '先に変更されています', 'current_status', v_a.status);
  end if;

  -- 既存の採用の処理を、押した人の操作として呼ぶ（呼ぶあいだだけ「だれの操作か」を切り替え、終わったら戻す。失敗したら、戻してから同じエラーを上げる）
  v_old_claims := current_setting('request.jwt.claims', true);
  v_old_sub := current_setting('request.jwt.claim.sub', true);
  begin
    perform set_config('request.jwt.claims', jsonb_build_object('sub', v_actor, 'role', 'authenticated')::text, true);
    perform set_config('request.jwt.claim.sub', v_actor::text, true);
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
  update applicants set last_actor_id = v_actor, last_actor_at = now() where id = p_applicant;
  select i.id into v_inv from invitations i where i.token = v_token;
  update invitations set employment_class = v_class where id = v_inv;   -- 2026-12-04: 雇用区分を、招待に控える（入社登録・賃金の承認へ引き継ぐ口）
  v_id := recruit_op_log(p_applicant, 'hire', v_actor, v_via, v_key, v_before, v_after || jsonb_build_object('invitation_id', v_inv, 'employment_class', v_class), 'done', null, null);
  if v_base is not null then v_text := join_invite_message(p_applicant, v_base || '?invite=' || v_token); end if;
  return jsonb_build_object('ok', true, 'code', 'done', 'op_id', v_id, 'applicant_name', v_a.name, 'actor_name', (select u.name from users u where u.id = v_actor),
    'role', p_role, 'kind', v_kind, 'linked', coalesce(btrim(coalesce(v_a.line_user_id, '')), '') <> '', 'is_test', v_test, 'invite_text', v_text, 'employment_class', v_class);
end $$;

-- ============ 4. 画面（管理システム）から採用にしたときに、雇用区分を招待に控える口 ============
--   画面は、既存の hire_applicant をそのまま呼ぶ（今までどおり）。そのあとに、これを呼んで、いま有効な招待に雇用区分を入れる。ログインしている本人・採用の権限・応募者の店舗を確かめる
create or replace function public.recruit_invite_class_set(p_applicant uuid, p_class text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_a record; v_kind text; v_n integer;
begin
  if auth.uid() is null then raise exception 'ログインが必要です'; end if;
  select a.id, a.store_id, a.form_key, a.invite_token into v_a from applicants a where a.id = p_applicant for update;
  if not found then return jsonb_build_object('ok', false, 'code', 'not_found', 'message', '応募者が見つかりません'); end if;
  if not (coalesce((select u.is_active from users u where u.id = auth.uid()), false) and has_feature(auth.uid(), 'recruit') and can_see_applicant(auth.uid(), v_a.store_id)) then
    return jsonb_build_object('ok', false, 'code', 'denied', 'message', '権限がありません');
  end if;
  if p_class is null or p_class not in ('arbeit', 'part', 'regular') then return jsonb_build_object('ok', false, 'code', 'bad_class', 'message', '雇用区分が正しくありません'); end if;
  v_kind := recruit_kind_of(v_a.form_key);
  if (v_kind = 'part' and p_class = 'regular') or (v_kind = 'employee' and p_class <> 'regular') then
    return jsonb_build_object('ok', false, 'code', 'bad_class', 'message', '雇用区分が、応募の区分と合っていません');
  end if;
  if v_a.invite_token is null then return jsonb_build_object('ok', false, 'code', 'no_invite', 'message', '招待がありません'); end if;
  update invitations set employment_class = p_class where token = v_a.invite_token and applicant_id = v_a.id and used_at is null;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', v_n = 1, 'code', case when v_n = 1 then 'done' else 'no_invite' end);
end $$;

-- ============ 5. 入社登録・賃金の承認へ渡す口（読むだけ） ============
--   その従業員が入社のときに使った招待の雇用区分を返す。{"detail": "arbeit|part|regular", "employment_class": "part|regular"（賃金の承認の分け方）, "invitation_id", "source": "invitation"}。控えが無ければ null
--   ★ 賃金の承認の判定（onboarding_wage_rule）は、まだこれを読まない。判定の側で読むようにする変更は、メモ §事実 に書いた
create or replace function public.recruit_employment_hint(p_user uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('detail', i.employment_class, 'employment_class', case when i.employment_class = 'regular' then 'regular' else 'part' end, 'invitation_id', i.id, 'source', 'invitation')
    from invitations i
   where i.used_by = p_user and i.employment_class is not null and (onboarding_is_service() or hq_can_manage())
   order by i.used_at desc nulls last limit 1
$$;

-- ============ 6. 権限 ============
revoke all on function public.recruit_hire_info(uuid, uuid), public.recruit_hire(uuid, text, uuid[], text, uuid, text, jsonb, text, text),
  public.recruit_invite_class_set(uuid, text), public.recruit_employment_hint(uuid) from public, anon, authenticated;
grant execute on function public.recruit_hire_info(uuid, uuid) to service_role;
-- recruit_hire は、画面（ログインしている本人）からも呼ぶ。中で、採用の権限・応募者の店舗・雇用区分・社員採用は社長だけ、を確かめる
grant execute on function public.recruit_hire(uuid, text, uuid[], text, uuid, text, jsonb, text, text), public.recruit_invite_class_set(uuid, text), public.recruit_employment_hint(uuid) to authenticated, service_role;

-- ============ 確認用（読むだけ） ============
-- select employment_class, count(*) from invitations group by 1;
