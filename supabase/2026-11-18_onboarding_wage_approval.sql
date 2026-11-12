-- =============================================================
-- 2026-11-18 入社時の賃金の承認（下書き・★本番未適用。適用は別途承認）
--   決定（ユーザー）:
--     ・アルバイト … 社長の承認は不要。権限のある担当者が入力・確定したら、スマレジへ自動反映する。
--     ・社員       … 社長の最終承認が必須。担当者が入力しただけでは、正式な賃金（employee_wage_settings）に入れない＝スマレジへ送られない。
--                    社長が管理システムの画面で承認したとき、初めて正式な賃金になる（スマレジへの反映と照合は Edge Function が続けて行う）。
--     ・判定は、給与形態（時給・月給）だけでなく、正式な雇用区分（users.role）を基準にする。不明・食い違いは「確認待ち」にして自動反映しない。
--     ・AI が賃金を推測して決めることはしない（この SQL は金額の妥当性を判断しない。形のチェックだけ）。
--   ほかの機能との境界（混同しない・どれも変えない）:
--     ・スマレジ側で直接変えられた賃金の控え wage_external_changes（未承認 12 件）… 触らない。一括承認もしない。
--     ・スイッチ B（employee_change.wage_import_hold）・賃金 2 段階承認（employee_change.wage_approval_required・approval_routes の wage）・
--       給与安全確認（payroll_wage_guard）・取り込み前チェック（wage_import_precheck）… 値を読まない・変えない。
--     ・既存従業員の変更申請（profile_change_requests・pay_change_*）… 使わない。この機能は「入社手続き中の人」専用の別の表。
--     ・hr_save_wage は変えない（この SQL の関数が、条件を満たしたときだけ呼ぶ）。
--   切り替え: app_settings.onboarding_wage_approval.enabled（既定 false）。false のあいだは、適用しても今までと同じ動き。
--   戻し方: 2026-11-18_onboarding_wage_approval_rollback.sql
--   適用: python3 scripts/apply_sql.py supabase/2026-11-18_onboarding_wage_approval.sql [--dry-run]
-- =============================================================

-- -------------------------------------------------------------
-- 0) 設定（既定は無効）
--    enabled       … true で、この承認のしくみが動く
--    block_direct  … true のあいだ、入社手続き中の人の賃金を「確定依頼」を通さずに直接入れることを止める（enabled=true のときだけ効く）
--    confirmer_ids … 賃金を入力・確定できる人を絞るときに users.id を並べる。空なら 本部・社長・マスター の全員（＝今の hr_save_wage と同じ）
-- -------------------------------------------------------------
insert into public.app_settings(key, value)
select 'onboarding_wage_approval',
       jsonb_build_object('enabled', false, 'block_direct', true, 'confirmer_ids', '[]'::jsonb,
                          'note', '2026-11-18 入社時の賃金の承認。enabled を true にすると、アルバイト×時給はその場で確定・社員などは社長の承認待ちになる')
where not exists (select 1 from public.app_settings where key = 'onboarding_wage_approval');

-- -------------------------------------------------------------
-- 1) 表: 入社時の賃金の確定依頼（1 回の入力で 1 行。入れ直すと前の承認待ちは取り下げになり、新しい行ができる＝金額の履歴が残る）
--    金額は wage_rows の中だけ。画面からは直接読めない（下の関数が、権限のある人にだけ返す）
-- -------------------------------------------------------------
create table if not exists public.onboarding_wage_requests (
  id               uuid primary key default gen_random_uuid(),
  workflow_id      uuid not null references public.onboarding_workflows(id) on delete cascade,
  user_id          uuid not null references public.users(id) on delete cascade,              -- 入社する人
  wage_rows        jsonb not null,            -- [{contract_id, division(0 時給/1 日給/2 月給), store_id, wage, holiday_wage, effective_date}]
  contract_ids     text[] not null default '{}'::text[],       -- 金額を読まずにスマレジ反映の対象を知るための写し
  divisions        integer[] not null default '{}'::integer[], -- 同上（給与形態）
  effective_from   date,                                       -- 同上（いちばん早い適用開始日）
  rule_result      text not null check (rule_result in ('none', 'president', 'hold')),       -- none=承認なし／president=社長の承認／hold=確認待ち（社長の承認に回す）
  rule_reason      text,                      -- 判定の理由（画面と Slack に出す。金額は入れない）
  rule_detail      jsonb,                     -- 判定に使った値の控え（その時点の役割・入社登録の区分・招待の区分・給与形態）
  status           text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  requested_by     uuid not null,             -- 入力者
  requested_at     timestamptz not null default now(),
  requested_via    text not null default 'nippo' check (requested_via in ('slack', 'nippo', 'system')),
  decided_by       uuid,                      -- 確定者（承認なしのときは入力者と同じ人）・承認者・却下した人・取り下げた人
  decided_at       timestamptz,
  decision_note    text,                      -- 却下の理由・取り下げの理由
  applied_at       timestamptz,               -- 正式な賃金（employee_wage_settings）に入れた日時
  wage_setting_ids uuid[],                    -- 入れた行（employee_wage_settings.id）
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
-- 承認待ちは、1 つの入社登録に 1 件まで
create unique index if not exists onboarding_wage_requests_pending_uq on public.onboarding_wage_requests(workflow_id) where status = 'pending';
create index if not exists onboarding_wage_requests_user_idx on public.onboarding_wage_requests(user_id, requested_at);
comment on table public.onboarding_wage_requests is '入社時の賃金の確定依頼（入社手続き中の人だけ）。アルバイト×時給は入力と同時に approved、社員などは社長の承認まで pending。既存従業員の賃金変更（profile_change_requests）・スマレジ側の変更の控え（wage_external_changes）とは別物';

-- 履歴（だれが・いつ・何をしたか。金額は入れない＝金額の履歴は確定依頼の行そのもの）
create table if not exists public.onboarding_wage_request_events (
  id          bigserial primary key,
  request_id  uuid not null references public.onboarding_wage_requests(id) on delete cascade,
  workflow_id uuid not null,
  kind        text not null check (kind in ('submitted', 'confirmed', 'approved', 'rejected', 'cancelled', 'superseded', 'apply_failed')),
              -- submitted=入力／confirmed=承認なしで確定／approved=社長が承認／rejected=社長が却下／cancelled=取り下げ／superseded=入れ直しで取り下げ／apply_failed=承認したが登録できなかった
  actor_id    uuid,
  via         text,
  detail      jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists onboarding_wage_request_events_req_idx on public.onboarding_wage_request_events(request_id, id);
create index if not exists onboarding_wage_request_events_wf_idx on public.onboarding_wage_request_events(workflow_id, id);

-- 画面（ログインしている人）からは、表を直接読めない・書けない。読むのは下の関数、書くのも下の関数だけ
alter table public.onboarding_wage_requests       enable row level security;
alter table public.onboarding_wage_request_events enable row level security;
revoke all on public.onboarding_wage_requests       from public, anon, authenticated;
revoke all on public.onboarding_wage_request_events from public, anon, authenticated;
grant select on public.onboarding_wage_requests       to service_role;   -- Edge Function は、金額の列（wage_rows）を選ばずに状態だけ読む
grant select on public.onboarding_wage_request_events to service_role;

-- -------------------------------------------------------------
-- 2) 共通の部品
-- -------------------------------------------------------------
-- 設定を読む
create or replace function public.onboarding_wage_cfg()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce((select s.value from app_settings s where s.key = 'onboarding_wage_approval'), '{}'::jsonb)
$$;
revoke all on function public.onboarding_wage_cfg() from public, anon, authenticated;

-- 操作者を決める: ログインしている人（p_actor は無視＝なりすまし防止）か、Edge Function（service_role）から渡された人。権限はここでは見ない
create or replace function public.onboarding_wage_actor(p_actor uuid)
returns uuid language plpgsql stable set search_path to 'public' as $$
begin
  if auth.uid() is not null then return auth.uid(); end if;
  if not public.onboarding_is_service() then raise exception '認証が必要です'; end if;
  if p_actor is null then raise exception '操作者が特定できません'; end if;
  return p_actor;
end $$;
revoke all on function public.onboarding_wage_actor(uuid) from public, anon;

-- 権限の判定
--   confirm … 賃金を入力・確定できる: 本部・社長・マスター（hr_save_wage と同じ）。設定 confirmer_ids に人が並んでいれば、その人だけに絞る
--   approve … 社員などの賃金を承認・却下できる: 役割が社長（CEO）の人だけ。マスター権限では代用できない
--   view    … 金額を見られる: 本部・社長・マスター（正式な賃金の表 employee_wage_settings を読める人と同じ）
create or replace function public.onboarding_wage_can(p_user uuid, p_what text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1
      from users u
     cross join (select public.onboarding_wage_cfg() -> 'confirmer_ids' as ids) c
     where u.id = p_user and u.is_active
       and case p_what
             when 'approve' then u.role = 'CEO'
             when 'view'    then (coalesce(u.is_master, false) or u.role in ('CEO', 'HQ'))
             when 'confirm' then (coalesce(u.is_master, false) or u.role in ('CEO', 'HQ'))
                                 and case when jsonb_typeof(c.ids) is distinct from 'array' then true
                                          when jsonb_array_length(c.ids) = 0 then true
                                          else c.ids ? u.id::text end
             else false end)
$$;
revoke all on function public.onboarding_wage_can(uuid, text) from public, anon, authenticated;

-- 入力された行の形を確かめて、そろえた形で返す（hr_save_wage と同じ決まり。金額が妥当かどうかは判断しない）
create or replace function public.onboarding_wage_rows_norm(p_rows jsonb, p_default_contract text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_out jsonb := '[]'::jsonb; v_row jsonb; v_div integer; v_wage integer; v_hol integer; v_date date; v_store uuid; v_contract text;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception '賃金の行がありません'; end if;
  if jsonb_array_length(p_rows) > 20 then raise exception '賃金の行が多すぎます（20 行まで）'; end if;
  for v_row in select e.value from jsonb_array_elements(p_rows) e loop
    begin
      v_div   := (v_row ->> 'division')::integer;
      v_wage  := (v_row ->> 'wage')::integer;
      v_hol   := nullif(v_row ->> 'holiday_wage', '')::integer;
      v_date  := (v_row ->> 'effective_date')::date;
      v_store := nullif(v_row ->> 'store_id', '')::uuid;
    exception when others then
      raise exception '賃金の行の形が正しくありません（給与形態・金額・適用開始日を確かめてください）';
    end;
    v_contract := coalesce(nullif(v_row ->> 'contract_id', ''), p_default_contract);
    if v_div is null or v_div not in (0, 1, 2) then raise exception '給与形態は時給(0)・日給(1)・月給(2)のいずれかを指定してください'; end if;
    if v_wage is null or v_wage <= 0 or v_wage > 100000000 then raise exception '金額が不正です'; end if;
    if v_date is null or v_date < date '2000-01-01' then raise exception '適用開始日を指定してください'; end if;
    if v_contract is null then raise exception 'スマレジの契約が決まっていません'; end if;
    if not exists (select 1 from smaregi_contracts sc where sc.contract_id = v_contract and sc.is_active) then raise exception 'スマレジの契約が見つかりません'; end if;
    if v_div in (1, 2) then
      if v_store is not null then raise exception '月給・日給は店舗を指定できません'; end if;
      if extract(day from v_date) <> 1 then raise exception '月給・日給の適用開始日は月初日（1日）にしてください'; end if;
      v_hol := null;
    end if;
    if v_div = 1 and v_wage > 1000000 then raise exception '日給が大きすぎます'; end if;
    if v_div = 0 and v_wage > 100000 then raise exception '時給が大きすぎます。月給は「月給」で入力してください'; end if;
    if v_hol is not null and v_hol < 0 then raise exception '休日賃金が不正です'; end if;
    if v_store is not null and not exists (select 1 from stores st where st.id = v_store) then raise exception '店舗が見つかりません'; end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'contract_id', v_contract, 'division', v_div, 'store_id', v_store, 'wage', v_wage, 'holiday_wage', v_hol, 'effective_date', v_date));
  end loop;
  return v_out;
end $$;
revoke all on function public.onboarding_wage_rows_norm(jsonb, text) from public, anon, authenticated;

-- 正式な賃金に入れる（hr_save_wage を行ごとに呼ぶ）。この関数を通したときだけ、下の「直接登録の制限」を通る
create or replace function public.onboarding_wage_apply(p_marker text, p_user uuid, p_rows jsonb, p_actor uuid)
returns uuid[] language plpgsql security definer set search_path to 'public' as $$
declare v_row jsonb; v_res jsonb; v_ids uuid[] := '{}'::uuid[];
begin
  perform set_config('onboarding_wage.via_approval', coalesce(nullif(p_marker, ''), '1'), true);
  for v_row in select e.value from jsonb_array_elements(p_rows) e loop
    v_res := public.hr_save_wage(
      p_user, v_row ->> 'contract_id', (v_row ->> 'division')::integer, nullif(v_row ->> 'store_id', '')::uuid,
      (v_row ->> 'wage')::integer, nullif(v_row ->> 'holiday_wage', '')::integer, (v_row ->> 'effective_date')::date, p_actor);
    v_ids := array_append(v_ids, (v_res ->> 'id')::uuid);
  end loop;
  perform set_config('onboarding_wage.via_approval', '', true);
  return v_ids;
end $$;
revoke all on function public.onboarding_wage_apply(text, uuid, jsonb, uuid) from public, anon, authenticated;

-- 画面（ログインしている人）から操作されたとき、Slack の表示とスマレジ反映を Edge Function onboarding-notify に頼む（op=wage_decided）。
--   Edge Function（Slack）から呼ばれたときは、Edge Function 自身が続きを行うので何もしない。
--   送るのは 依頼の id・入社登録の id・出来事の名前 だけ（金額・氏名は送らない）。失敗しても、承認などの処理そのものは止めない。
create or replace function public.onboarding_wage_notify(p_request uuid, p_workflow uuid, p_event text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then return; end if;
  begin
    perform public.pay_change_notify_op('wage_decided', jsonb_build_object('request_id', p_request, 'workflow_id', p_workflow, 'event', p_event));
  exception when others then
    raise warning 'onboarding_wage_notify: %', sqlerrm;
  end;
end $$;
revoke all on function public.onboarding_wage_notify(uuid, uuid, text) from public, anon, authenticated;

-- -------------------------------------------------------------
-- 3) 判定: 正式な雇用区分（users.role）× 給与形態 → 承認なし（none）／社長の承認（president）／確認待ち（hold）
--    p_rows を渡さないと、雇用区分だけの仮の判定を返す（画面の案内用）
--    雇用区分の見方は、既存の post_join_class（アルバイト＝AL・それ以外＝社員の扱い）と同じ
-- -------------------------------------------------------------
create or replace function public.onboarding_wage_rule(p_workflow uuid, p_rows jsonb default null)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  wf onboarding_workflows%rowtype; v_role text; v_wf_role text; v_inv_role text; v_divs integer[]; v_rule text; v_reason text;
  v_label jsonb := '{"AL":"アルバイト","SHAIN":"社員","TENCHO":"店長","TEAM":"チーム長","HQ":"本部","CEO":"社長"}'::jsonb;
begin
  select * into wf from onboarding_workflows w where w.id = p_workflow;
  if wf.id is null or wf.user_id is null then
    return jsonb_build_object('rule', 'hold', 'reason', '入社登録が見つかりません');
  end if;
  select nullif(btrim(u.role), '') into v_role from users u where u.id = wf.user_id;
  v_wf_role := nullif(btrim(wf.role), '');
  if wf.invitation_id is not null then
    select nullif(btrim(i.role), '') into v_inv_role from invitations i where i.id = wf.invitation_id;
  end if;
  if p_rows is not null and jsonb_typeof(p_rows) = 'array' and jsonb_array_length(p_rows) > 0 then
    select array_agg(distinct (e.value ->> 'division')::integer order by (e.value ->> 'division')::integer) into v_divs
      from jsonb_array_elements(p_rows) e;
  end if;

  if v_role is null then
    v_rule := 'hold'; v_reason := '雇用区分（役割）が登録されていません';
  elsif v_role not in ('AL', 'SHAIN', 'TENCHO', 'TEAM', 'HQ', 'CEO') then
    v_rule := 'hold'; v_reason := '雇用区分（役割）が想定していない値です';
  elsif v_role = 'CEO' then
    v_rule := 'hold'; v_reason := '社長本人の賃金・役員報酬は、この手続きでは決められません（正式な決定手続きに基づく別の手続き）';
  elsif v_wf_role is distinct from v_role then
    v_rule := 'hold'; v_reason := '入社登録を始めた時の区分（' || coalesce(v_label ->> v_wf_role, v_wf_role, '記録なし') || '）と、今の区分（' || coalesce(v_label ->> v_role, v_role) || '）が違います';
  elsif v_inv_role is not null and v_inv_role <> v_role then
    v_rule := 'hold'; v_reason := '招待（採用）の時の区分（' || coalesce(v_label ->> v_inv_role, v_inv_role) || '）と、今の区分（' || coalesce(v_label ->> v_role, v_role) || '）が違います';
  elsif v_divs is null then
    -- 行が無い（仮の判定）: 区分だけで答える
    if v_role = 'AL' then v_rule := 'none'; v_reason := 'アルバイトの時給は、担当者の確定でスマレジへ反映します（月給・日給を選ぶと確認待ちになります）';
    else v_rule := 'president'; v_reason := coalesce(v_label ->> v_role, v_role) || 'の賃金は、社長の最終承認が必要です'; end if;
  elsif 1 = any(v_divs) then
    v_rule := 'hold'; v_reason := '日給は、いまの在職者に登録が無い給与形態です（確認が必要）';
  elsif cardinality(v_divs) > 1 then
    v_rule := 'hold'; v_reason := '時給と月給が混ざっています（確認が必要）';
  elsif v_role = 'AL' then
    if v_divs[1] = 0 then v_rule := 'none'; v_reason := 'アルバイトの時給（社長の承認は不要）';
    else v_rule := 'hold'; v_reason := 'アルバイトなのに月給です（雇用区分と給与形態が合いません）'; end if;
  elsif v_role in ('SHAIN', 'TENCHO') then
    if v_divs[1] = 2 then v_rule := 'president'; v_reason := coalesce(v_label ->> v_role, v_role) || 'の賃金は、社長の最終承認が必要です';
    else v_rule := 'hold'; v_reason := coalesce(v_label ->> v_role, v_role) || 'なのに時給です（雇用区分と給与形態が合いません）'; end if;
  else
    -- チーム長・本部: 月給は社員として社長の承認。時給は、役割からは社員かアルバイトかを決められないので確認待ち
    if v_divs[1] = 2 then v_rule := 'president'; v_reason := coalesce(v_label ->> v_role, v_role) || 'の賃金は、社長の最終承認が必要です';
    else v_rule := 'hold'; v_reason := coalesce(v_label ->> v_role, v_role) || 'で時給です（役割からは、社員かアルバイトかを決められません）'; end if;
  end if;

  return jsonb_build_object('rule', v_rule, 'reason', v_reason, 'role', v_role, 'role_label', v_label ->> v_role,
    'class', case when v_role is null then null else public.post_join_class(v_role) end,
    'workflow_role', v_wf_role, 'invite_role', v_inv_role, 'divisions', to_jsonb(v_divs));
end $$;
revoke all on function public.onboarding_wage_rule(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.onboarding_wage_rule(uuid, jsonb) to service_role;

-- -------------------------------------------------------------
-- 4) 入力: 判定が「承認なし」ならその場で正式な賃金にする。「社長の承認」「確認待ち」なら、確定依頼を承認待ちで作るだけ
--    （正式な賃金の表には入れない＝スマレジへは送られない）。
--    設定が無効のあいだは、今までと同じ（すぐ hr_save_wage。確定依頼の行は作らない）。
--    戻り値の applied が true のとき、呼び出し側（Edge Function）が続けてスマレジへ反映する
-- -------------------------------------------------------------
create or replace function public.onboarding_wage_submit(p_workflow uuid, p_rows jsonb, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  wf onboarding_workflows%rowtype; v_actor uuid; v_via text; v_rows jsonb; v_judge jsonb; v_rule text; v_reason text;
  v_req uuid; v_old uuid; v_ids uuid[]; v_contracts text[]; v_divs integer[]; v_from date;
begin
  v_actor := public.onboarding_wage_actor(p_actor);
  v_via := case when auth.uid() is null then 'slack' else 'nippo' end;
  select * into wf from onboarding_workflows w where w.id = p_workflow for update;
  if wf.id is null or wf.user_id is null then raise exception '入社登録が見つかりません'; end if;
  if wf.status = 'cancelled' then raise exception 'この入社手続きは中止されています'; end if;
  v_rows := public.onboarding_wage_rows_norm(p_rows, wf.contract_id);
  select array_agg(distinct e.value ->> 'contract_id'), array_agg(distinct (e.value ->> 'division')::integer), min((e.value ->> 'effective_date')::date)
    into v_contracts, v_divs, v_from
    from jsonb_array_elements(v_rows) e;

  -- 設定が無効: 今までどおり（権限と検証は hr_save_wage が行う）
  if not coalesce((public.onboarding_wage_cfg() ->> 'enabled')::boolean, false) then
    v_ids := public.onboarding_wage_apply('legacy', wf.user_id, v_rows, v_actor);
    return jsonb_build_object('ok', true, 'mode', 'legacy', 'applied', true, 'rule', 'none', 'contract_ids', to_jsonb(v_contracts));
  end if;

  -- ここから先は、設定が有効のとき
  if wf.status not in ('hired_confirmed', 'form_sent', 'registering') then
    raise exception '入社手続き中の人だけが対象です（この入社登録は完了しています。賃金の変更は、従業員ページから行ってください）';
  end if;
  if not public.onboarding_wage_can(v_actor, 'confirm') then raise exception '権限がありません（賃金を入力・確定できる担当者だけ）'; end if;
  if v_actor = wf.user_id then raise exception '自分の賃金は、自分では入力できません'; end if;

  v_judge := public.onboarding_wage_rule(p_workflow, v_rows);
  v_rule := v_judge ->> 'rule'; v_reason := v_judge ->> 'reason';

  -- 前の承認待ちがあれば取り下げる（入れ直し。行は残る＝履歴）
  for v_old in
    update onboarding_wage_requests q
       set status = 'cancelled', decision_note = '入れ直しのため取り下げ', decided_by = v_actor, decided_at = now(), updated_at = now()
     where q.workflow_id = p_workflow and q.status = 'pending'
    returning q.id
  loop
    insert into onboarding_wage_request_events(request_id, workflow_id, kind, actor_id, via) values (v_old, p_workflow, 'superseded', v_actor, v_via);
  end loop;

  insert into onboarding_wage_requests(workflow_id, user_id, wage_rows, contract_ids, divisions, effective_from, rule_result, rule_reason, rule_detail, status, requested_by, requested_via)
  values (p_workflow, wf.user_id, v_rows, coalesce(v_contracts, '{}'::text[]), coalesce(v_divs, '{}'::integer[]), v_from, v_rule, v_reason, v_judge, 'pending', v_actor, v_via)
  returning id into v_req;
  insert into onboarding_wage_request_events(request_id, workflow_id, kind, actor_id, via, detail)
  values (v_req, p_workflow, 'submitted', v_actor, v_via, jsonb_build_object('rule', v_rule, 'reason', v_reason));

  if v_rule = 'none' then
    -- 承認なし（アルバイト×時給）: その場で確定＝正式な賃金に入れる。入力者と確定者は同じ人
    v_ids := public.onboarding_wage_apply(v_req::text, wf.user_id, v_rows, v_actor);
    update onboarding_wage_requests q
       set status = 'approved', decided_by = v_actor, decided_at = now(), applied_at = now(), wage_setting_ids = v_ids, updated_at = now()
     where q.id = v_req;
    insert into onboarding_wage_request_events(request_id, workflow_id, kind, actor_id, via) values (v_req, p_workflow, 'confirmed', v_actor, v_via);
    perform public.onboarding_wage_notify(v_req, p_workflow, 'confirmed');
    return jsonb_build_object('ok', true, 'mode', 'approval', 'applied', true, 'rule', 'none', 'request_id', v_req, 'contract_ids', to_jsonb(v_contracts));
  end if;

  -- 社長の承認・確認待ち: 正式な賃金には入れない。入社登録の項目「賃金」を「手動対応が必要＝承認待ち」にする（金額は入れない）
  perform public.onboarding_set_item(p_workflow, 'wage', 'manual_required',
    jsonb_build_object('approval', 'pending', 'request_id', v_req, 'rule', v_rule, 'reason', v_reason, 'requested_by', v_actor),
    v_actor, v_via,
    case when v_rule = 'hold' then '確認待ち（社長の承認が必要）: ' || left(coalesce(v_reason, ''), 60) else '社長の承認待ち' end);
  perform public.onboarding_wage_notify(v_req, p_workflow, 'submitted');
  return jsonb_build_object('ok', true, 'mode', 'approval', 'applied', false, 'rule', v_rule, 'reason', v_reason, 'request_id', v_req);
end $$;
revoke all on function public.onboarding_wage_submit(uuid, jsonb, uuid) from public, anon;
grant execute on function public.onboarding_wage_submit(uuid, jsonb, uuid) to authenticated, service_role;

-- -------------------------------------------------------------
-- 5) 承認・却下（社長だけ。マスター権限では代用できない。自分の賃金は承認できない）
--    承認: ここで初めて hr_save_wage を呼ぶ＝正式な賃金になる（スマレジへの反映と照合は Edge Function が続けて行う）
--    却下: 正式な賃金には入れない。項目「賃金」は入れ直し待ちになる
-- -------------------------------------------------------------
create or replace function public.onboarding_wage_decide(p_request uuid, p_approve boolean, p_note text default null, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  q onboarding_wage_requests%rowtype; wf onboarding_workflows%rowtype; v_actor uuid; v_via text; v_ids uuid[]; v_err text; v_now jsonb;
begin
  v_actor := public.onboarding_wage_actor(p_actor);
  v_via := case when auth.uid() is null then 'system' else 'nippo' end;
  if p_approve is null then raise exception '承認か却下かを指定してください'; end if;
  select * into q from onboarding_wage_requests x where x.id = p_request for update;
  if q.id is null then raise exception '確定依頼が見つかりません'; end if;
  if not public.onboarding_wage_can(v_actor, 'approve') then raise exception '承認・却下できるのは社長だけです（マスター権限では代用できません）'; end if;
  if v_actor = q.user_id then raise exception '自分の賃金は、自分では承認・却下できません'; end if;
  if q.status <> 'pending' then
    return jsonb_build_object('ok', false, 'error', 'この確定依頼は処理済みです', 'status', q.status);
  end if;
  select * into wf from onboarding_workflows w where w.id = q.workflow_id for update;

  if not p_approve then
    if coalesce(btrim(p_note), '') = '' then raise exception '却下の理由を入れてください'; end if;
    update onboarding_wage_requests x
       set status = 'rejected', decided_by = v_actor, decided_at = now(), decision_note = left(btrim(p_note), 500), updated_at = now()
     where x.id = q.id;
    insert into onboarding_wage_request_events(request_id, workflow_id, kind, actor_id, via) values (q.id, q.workflow_id, 'rejected', v_actor, v_via);
    if wf.id is not null and wf.status <> 'cancelled' then
      perform public.onboarding_set_item(q.workflow_id, 'wage', 'manual_required',
        jsonb_build_object('approval', 'rejected', 'request_id', q.id, 'decided_by', v_actor),
        v_actor, case when auth.uid() is null then 'auto' else 'nippo' end, '社長が却下しました（賃金を入れ直してください）');
    end if;
    perform public.onboarding_wage_notify(q.id, q.workflow_id, 'rejected');
    return jsonb_build_object('ok', true, 'status', 'rejected', 'request_id', q.id, 'workflow_id', q.workflow_id);
  end if;

  -- 承認
  if wf.id is null or wf.status = 'cancelled' then
    return jsonb_build_object('ok', false, 'error', 'この入社手続きは中止されているため、承認できません（取り下げてください）', 'status', q.status);
  end if;
  begin
    v_ids := public.onboarding_wage_apply(q.id::text, q.user_id, q.wage_rows, v_actor);
  exception when others then
    v_err := sqlerrm;
    perform set_config('onboarding_wage.via_approval', '', true);
  end;
  if v_err is not null then
    -- 登録できなかった（例: 契約が無効になった）。承認待ちのまま残し、理由を返す
    insert into onboarding_wage_request_events(request_id, workflow_id, kind, actor_id, via, detail)
    values (q.id, q.workflow_id, 'apply_failed', v_actor, v_via, jsonb_build_object('error', left(v_err, 300)));
    return jsonb_build_object('ok', false, 'error', '承認できませんでした（賃金を登録できません）: ' || left(v_err, 300), 'status', 'pending');
  end if;
  v_now := public.onboarding_wage_rule(q.workflow_id, q.wage_rows);   -- 承認した時点の判定も控えに残す
  update onboarding_wage_requests x
     set status = 'approved', decided_by = v_actor, decided_at = now(), decision_note = nullif(left(btrim(coalesce(p_note, '')), 500), ''),
         applied_at = now(), wage_setting_ids = v_ids, updated_at = now()
   where x.id = q.id;
  insert into onboarding_wage_request_events(request_id, workflow_id, kind, actor_id, via, detail)
  values (q.id, q.workflow_id, 'approved', v_actor, v_via, jsonb_build_object('rule_at_decision', v_now ->> 'rule', 'reason_at_decision', v_now ->> 'reason'));
  perform public.onboarding_set_item(q.workflow_id, 'wage', 'running',
    jsonb_build_object('approval', 'approved', 'request_id', q.id, 'decided_by', v_actor),
    v_actor, case when auth.uid() is null then 'auto' else 'nippo' end, null);
  perform public.onboarding_wage_notify(q.id, q.workflow_id, 'approved');
  return jsonb_build_object('ok', true, 'status', 'approved', 'request_id', q.id, 'workflow_id', q.workflow_id, 'user_id', q.user_id, 'contract_ids', to_jsonb(q.contract_ids));
end $$;
revoke all on function public.onboarding_wage_decide(uuid, boolean, text, uuid) from public, anon;
grant execute on function public.onboarding_wage_decide(uuid, boolean, text, uuid) to authenticated, service_role;

-- -------------------------------------------------------------
-- 6) 取り下げ（承認待ちのものだけ。入力した人か、入力・確定できる担当者）
-- -------------------------------------------------------------
create or replace function public.onboarding_wage_cancel(p_request uuid, p_note text default null, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare q onboarding_wage_requests%rowtype; v_actor uuid; v_via text;
begin
  v_actor := public.onboarding_wage_actor(p_actor);
  v_via := case when auth.uid() is null then 'slack' else 'nippo' end;
  select * into q from onboarding_wage_requests x where x.id = p_request for update;
  if q.id is null then raise exception '確定依頼が見つかりません'; end if;
  if not public.onboarding_wage_can(v_actor, 'confirm') then raise exception '権限がありません（賃金を入力・確定できる担当者だけ）'; end if;
  if q.status <> 'pending' then return jsonb_build_object('ok', false, 'error', 'この確定依頼は処理済みです', 'status', q.status); end if;
  update onboarding_wage_requests x
     set status = 'cancelled', decided_by = v_actor, decided_at = now(), decision_note = nullif(left(btrim(coalesce(p_note, '')), 500), ''), updated_at = now()
   where x.id = q.id;
  insert into onboarding_wage_request_events(request_id, workflow_id, kind, actor_id, via) values (q.id, q.workflow_id, 'cancelled', v_actor, v_via);
  if exists (select 1 from onboarding_workflows w where w.id = q.workflow_id and w.status <> 'cancelled') then
    perform public.onboarding_set_item(q.workflow_id, 'wage', 'pending',
      jsonb_build_object('approval', 'cancelled', 'request_id', q.id), v_actor, v_via, null);
  end if;
  perform public.onboarding_wage_notify(q.id, q.workflow_id, 'cancelled');
  return jsonb_build_object('ok', true, 'status', 'cancelled', 'request_id', q.id, 'workflow_id', q.workflow_id);
end $$;
revoke all on function public.onboarding_wage_cancel(uuid, text, uuid) from public, anon;
grant execute on function public.onboarding_wage_cancel(uuid, text, uuid) to authenticated, service_role;

-- -------------------------------------------------------------
-- 7) 状況（画面と Slack 用）
--    ログインしている 本部・社長・マスター … 金額（rows）と却下の理由も返す
--    Edge Function（Slack 用）              … 金額と却下の理由は返さない（状態・判定・だれが・いつ だけ）
--    p_workflow を省くと、全員ぶんの一覧（p_only_open=true なら承認待ちだけ）
-- -------------------------------------------------------------
create or replace function public.onboarding_wage_status(p_workflow uuid default null, p_actor uuid default null, p_only_open boolean default true)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_viewer uuid; v_amount boolean := false; v_list jsonb; v_events jsonb := null;
begin
  if auth.uid() is not null then
    v_viewer := auth.uid();
    if not public.onboarding_wage_can(v_viewer, 'view') then raise exception '権限がありません（本部・社長・マスターのみ）'; end if;
    v_amount := true;
  elsif public.onboarding_is_service() then
    v_viewer := p_actor;
  else
    raise exception '認証が必要です';
  end if;

  select coalesce(jsonb_agg(x.j order by x.requested_at desc), '[]'::jsonb) into v_list
    from (
      select q.requested_at,
             jsonb_build_object(
               'id', q.id, 'workflow_id', q.workflow_id, 'user_id', q.user_id,
               'user_name', (select u.name from users u where u.id = q.user_id),
               'user_role', (select u.role from users u where u.id = q.user_id),
               'status', q.status, 'rule', q.rule_result, 'reason', q.rule_reason,
               'divisions', to_jsonb(q.divisions), 'contract_ids', to_jsonb(q.contract_ids), 'effective_from', q.effective_from,
               'requested_by', q.requested_by, 'requested_by_name', (select u.name from users u where u.id = q.requested_by),
               'requested_at', q.requested_at, 'requested_via', q.requested_via,
               'decided_by', q.decided_by, 'decided_by_name', (select u.name from users u where u.id = q.decided_by),
               'decided_at', q.decided_at, 'applied_at', q.applied_at,
               'can_decide', (q.status = 'pending' and v_viewer is not null and v_viewer <> q.user_id and public.onboarding_wage_can(v_viewer, 'approve')),
               'can_cancel', (q.status = 'pending' and v_viewer is not null and public.onboarding_wage_can(v_viewer, 'confirm')))
             || case when v_amount then jsonb_build_object('rows', q.wage_rows, 'decision_note', q.decision_note) else '{}'::jsonb end as j
        from onboarding_wage_requests q
       where (p_workflow is null or q.workflow_id = p_workflow)
         and (not coalesce(p_only_open, true) or q.status = 'pending')
       order by q.requested_at desc
       limit 200
    ) x;

  if p_workflow is not null then
    select coalesce(jsonb_agg(jsonb_build_object('request_id', e.request_id, 'kind', e.kind, 'actor_id', e.actor_id,
             'actor_name', (select u.name from users u where u.id = e.actor_id), 'via', e.via, 'at', e.created_at) order by e.id), '[]'::jsonb)
      into v_events
      from onboarding_wage_request_events e where e.workflow_id = p_workflow;
  end if;

  return jsonb_build_object(
    'ok', true,
    'enabled', coalesce((public.onboarding_wage_cfg() ->> 'enabled')::boolean, false),
    'viewer', jsonb_build_object(
      'can_confirm', v_viewer is not null and public.onboarding_wage_can(v_viewer, 'confirm'),
      'can_approve', v_viewer is not null and public.onboarding_wage_can(v_viewer, 'approve'),
      'amounts', v_amount),
    'requests', v_list,
    'events', v_events,
    'rule', case when p_workflow is null then null else public.onboarding_wage_rule(p_workflow, null) end);
end $$;
revoke all on function public.onboarding_wage_status(uuid, uuid, boolean) from public, anon;
grant execute on function public.onboarding_wage_status(uuid, uuid, boolean) to authenticated, service_role;

-- -------------------------------------------------------------
-- 8) 直接登録の制限（設定が有効のときだけ）
--    入社手続き中の人の賃金は、上の関数（確定依頼）を通したときだけ正式な賃金の表に入る。
--    従業員ページの賃金カードや、切り替え前の Slack の入力から hr_save_wage を直接呼んでも入らない（社員の賃金が社長の承認なしで入るのを防ぐ）。
--    止めるのは「人の操作」だけ。スマレジからの取り込み・同期状態の更新（ログインなし・created_by なし）は今までどおり通す。
--    入社手続きが終わった人・入社登録が無い人には何もしない（既存の employee_change_pay_guard とは別のもの）
-- -------------------------------------------------------------
create or replace function public.onboarding_wage_direct_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_cfg jsonb;
begin
  v_cfg := public.onboarding_wage_cfg();
  if not coalesce((v_cfg ->> 'enabled')::boolean, false) then return new; end if;
  if not coalesce((v_cfg ->> 'block_direct')::boolean, true) then return new; end if;
  if coalesce(current_setting('onboarding_wage.via_approval', true), '') <> '' then return new; end if;   -- 確定依頼からの登録
  if tg_op = 'UPDATE' and (new.wage, new.holiday_wage, new.effective_date, new.division, new.store_id, new.contract_id)
       is not distinct from (old.wage, old.holiday_wage, old.effective_date, old.division, old.store_id, old.contract_id) then
    return new;                                                                                             -- 同期状態だけの更新
  end if;
  if auth.uid() is null and not (tg_op = 'INSERT' and new.created_by is not null) then return new; end if;  -- システム処理（スマレジ同期・取り込み）
  if not exists (select 1 from onboarding_workflows w where w.user_id = new.user_id and w.status in ('hired_confirmed', 'form_sent', 'registering')) then
    return new;                                                                                             -- 入社手続き中ではない
  end if;
  raise exception '入社手続き中の人の賃金は、入社登録の「賃金の確定」から入れてください（社員の賃金は社長の承認が必要です）';
end $$;
revoke all on function public.onboarding_wage_direct_guard() from public, anon, authenticated;
drop trigger if exists onboarding_wage_direct_guard on public.employee_wage_settings;
create trigger onboarding_wage_direct_guard before insert or update on public.employee_wage_settings
  for each row execute function public.onboarding_wage_direct_guard();

-- -------------------------------------------------------------
-- 有効にするとき（★ 別途承認のあと・Edge Function と管理システムの画面を反映したあとに、手で）:
--   update public.app_settings set value = value || '{"enabled": true}'::jsonb where key = 'onboarding_wage_approval';
-- 無効に戻す（承認待ちの行と履歴は残る。正式な賃金には何も入らない）:
--   update public.app_settings set value = value || '{"enabled": false}'::jsonb where key = 'onboarding_wage_approval';
-- -------------------------------------------------------------
