-- =============================================================
-- 入社登録の自動化の残り（その 2）: 交通費を「1 回の承認」に（2026-11-12 ユーザー指示「交通費の1回承認化とスマレジへの自動登録」）
--   いま: ①「再検索」を押す ② 経路と金額を承認 ③「交通費を設定」で支給形態などを入力 の 3 回の操作。③ は承認していなくても押せる。
--   これから:
--     ・経路の検索は、入社フォームの送信のあと、見回り（10 分おき）が自動で始める（1 件につき 1 回だけ。やり直しは今までどおり「再検索」）。
--     ・本部が経路と金額を承認したら、会社のルールの初期値で交通費の設定を登録する（承認 1 回で済む）。
--         基本（1 日上限）＝勤務日数ごと・承認した片道×2 を 1 日上限（commute_rules.daily_cap_round_yen）で頭打ち
--         全額支給（本部の個別承認）＝勤務日数ごと・承認した片道×2
--         定期代支給（本部の個別承認）＝月額・検索で取れた定期 1 か月（取れていなければ自動では登録しない）
--         月額上限＝本部の個別設定 → 支給方法が基本でアルバイトなら al_cap_yen → それ以外は なし
--         適用開始日＝入社日（無ければ今日）／適用事業所＝全事業所
--       変えたいときだけ、今までどおり「交通費を設定」で入れ直す。
--     ・経路と片道額を承認していないあいだは、交通費の設定を登録できない（onboarding_set_commute_setting に確認を 1 か所足す）。
--   スマレジへ入れるのは今までどおり: 自動書き込みのスイッチ（commute_rules.smaregi_write_enabled）が true のときだけ待ち行列へ。false のあいだは「手で入力」の案内。
--   完了は今までどおり「スマレジを読み直して一致したときだけ」。未承認の賃金・既存のスイッチ・既存の交通費の設定データには触れない。
--   既存の関数の変更は onboarding_set_commute_setting の 1 か所（本番の定義に確認を足しただけ）と、見回り onboarding_auto_sweep（11-18 で足したもの）に 1 行。
--   戻し方: 2026-11-19_onboarding_commute_one_step_rollback.sql
-- =============================================================

-- 承認した内容から、スマレジに入れる交通費の初期値を作る（読むだけ）
create or replace function public.onboarding_commute_defaults(p_workflow uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare wf onboarding_workflows%rowtype; c employee_commute%rowtype; v_rules jsonb; v_policy text; v_cap int; v_contract text;
        v_type text; v_amount int; v_mcap int; v_date date; v_role text; v_teiki int;
begin
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null or wf.user_id is null then return jsonb_build_object('ok', false, 'error', 'no_workflow'); end if;
  select * into c from employee_commute where user_id = wf.user_id;
  if c.user_id is null or c.judgement is distinct from 'approved' or c.approved_fare is null then return jsonb_build_object('ok', false, 'error', 'not_approved'); end if;
  select l.contract_id into v_contract from employee_smaregi_links l join smaregi_contracts sc on sc.contract_id = l.contract_id and sc.is_active
   where l.user_id = wf.user_id and l.effective_to is null order by l.is_primary desc, l.effective_from desc limit 1;
  if v_contract is null then return jsonb_build_object('ok', false, 'error', 'no_contract'); end if;
  select value into v_rules from app_settings where key = 'commute_rules';
  v_policy := coalesce(c.pay_policy, 'daily_cap');
  v_cap := coalesce(nullif(v_rules ->> 'daily_cap_round_yen', '')::int, 500);
  select u.role into v_role from users u where u.id = wf.user_id;
  if v_policy = 'teiki' then
    v_teiki := coalesce(c.computed_teiki1, nullif(c.search_result #>> '{pay_plan,teiki1}', '')::int);
    if v_teiki is null then return jsonb_build_object('ok', false, 'error', 'no_teiki'); end if;
    v_type := 'monthly'; v_amount := v_teiki;
  elsif v_policy = 'full' then
    v_type := 'per_day'; v_amount := c.approved_fare * 2;
  else
    v_type := 'per_day'; v_amount := least(c.approved_fare * 2, v_cap);
  end if;
  v_mcap := case when c.monthly_cap_override is not null and c.monthly_cap_override >= 0 then c.monthly_cap_override
                 when v_policy <> 'daily_cap' then null
                 when v_role = 'AL' then case when v_rules ? 'al_cap_yen' then nullif(v_rules ->> 'al_cap_yen', '')::int else 6000 end
                 else null end;
  v_date := coalesce(wf.hire_date, (now() at time zone 'Asia/Tokyo')::date);
  return jsonb_build_object('ok', true, 'contract_id', v_contract, 'pay_type', v_type, 'amount', v_amount, 'cap_amount', v_mcap, 'effective_date', v_date, 'scope', 'all', 'policy', v_policy);
end $$;

-- 承認のあとに呼ぶ: まだ交通費の設定が無ければ、初期値で登録する（あれば何もしない）
create or replace function public.onboarding_commute_one_step(p_workflow uuid, p_actor uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d jsonb; r jsonb;
begin
  if auth.uid() is null and not public.onboarding_is_service() then raise exception '認証が必要です'; end if;
  if exists (select 1 from employee_commute_settings s where s.workflow_id = p_workflow and s.sync_status in ('pending', 'queued', 'synced', 'manual')) then
    return jsonb_build_object('ok', true, 'skipped', 'already_set');   -- すでに設定がある: 上書きしない（変えるときは「交通費を設定」から）
  end if;
  if exists (select 1 from onboarding_items i where i.workflow_id = p_workflow and i.item_key = 'commute_set' and i.state in ('completed', 'running', 'manual_running')) then
    return jsonb_build_object('ok', true, 'skipped', 'item_in_progress');
  end if;
  d := onboarding_commute_defaults(p_workflow);
  if not coalesce((d ->> 'ok')::boolean, false) then return jsonb_build_object('ok', true, 'skipped', d ->> 'error'); end if;
  r := onboarding_set_commute_setting(p_workflow, d ->> 'contract_id', d ->> 'pay_type', (d ->> 'effective_date')::date, 'all', (d ->> 'amount')::int, null,
                                      nullif(d ->> 'cap_amount', '')::int, null, '承認と同時に登録（会社のルールの初期値）', p_actor);
  return jsonb_build_object('ok', true, 'setting_id', r ->> 'setting_id', 'job', r -> 'job', 'defaults', d - 'contract_id');
end $$;

-- 経路の検索を自動で始める（1 件につき 1 回だけ）。始めたら true
create or replace function public.onboarding_commute_auto_search(p_workflow uuid)
returns boolean language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/onboarding-notify';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  wf onboarding_workflows%rowtype; v_secret text;
begin
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null or wf.status <> 'registering' or wf.user_id is null then return false; end if;
  if not exists (select 1 from onboarding_items i where i.workflow_id = wf.id and i.item_key = 'commute_check' and i.state = 'pending') then return false; end if;
  if not exists (select 1 from employee_commute ec where ec.user_id = wf.user_id and ec.judged_at is null and ec.judgement is distinct from 'approved') then return false; end if;   -- 通勤の申請が無い・もう検索した: 何もしない
  if exists (select 1 from onboarding_events e where e.workflow_id = wf.id and e.kind = 'commute.auto_search') then return false; end if;                                       -- 自動の検索は 1 回だけ
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  if v_secret is null or length(trim(v_secret)) = 0 then return false; end if;
  insert into onboarding_events(workflow_id, item_key, kind, via, after) values (wf.id, 'commute_check', 'commute.auto_search', 'auto', jsonb_build_object('at', now()));
  perform net.http_post(url := c_fn,
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
    body := jsonb_build_object('op', 'commute_check', 'workflow_id', wf.id), timeout_milliseconds := 60000);
  return true;
end $$;

revoke all on function public.onboarding_commute_defaults(uuid), public.onboarding_commute_one_step(uuid, uuid), public.onboarding_commute_auto_search(uuid) from public, anon, authenticated;
grant execute on function public.onboarding_commute_defaults(uuid), public.onboarding_commute_one_step(uuid, uuid), public.onboarding_commute_auto_search(uuid) to service_role;

-- 交通費の設定: 承認していなければ登録できない（本番の定義に、確認を 1 か所足しただけ）
CREATE OR REPLACE FUNCTION public.onboarding_set_commute_setting(p_workflow uuid, p_contract text, p_pay_type text, p_effective_date date, p_scope text, p_amount integer, p_store_amounts jsonb, p_cap_amount integer, p_cap_unit text, p_note text, p_actor uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_actor uuid; wf onboarding_workflows%rowtype; v_id uuid; v_job jsonb; v_payload jsonb;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  select * into wf from onboarding_workflows where id = p_workflow;
  if wf.id is null then raise exception 'ワークフローが見つかりません'; end if;
  -- 2026-11-19: 経路と片道額を承認していないあいだは、設定に進めない
  if not exists (select 1 from employee_commute ec where ec.user_id = wf.user_id and ec.judgement = 'approved' and ec.approved_fare is not null) then
    raise exception '交通費の経路と片道額がまだ承認されていません（先に承認してください）';
  end if;
  if p_pay_type not in ('per_shift','per_day','monthly') then raise exception '支給形態が不正です'; end if;
  if p_scope not in ('all','per_store') then raise exception '適用事業所の区分が不正です'; end if;
  if p_scope = 'all' and (p_amount is null or p_amount < 0) then raise exception '金額を指定してください'; end if;
  if p_scope = 'per_store' and (p_store_amounts is null or p_store_amounts = '{}'::jsonb) then raise exception '事業所ごとの金額を指定してください'; end if;
  if p_effective_date is null then raise exception '適用開始日を指定してください'; end if;
  update employee_commute_settings set sync_status = case when sync_status in ('pending','queued') then 'manual' else sync_status end, updated_at = now()
   where user_id = wf.user_id and contract_id = p_contract and sync_status in ('pending','queued');   -- 未反映の古い指示は取り下げ
  insert into employee_commute_settings(user_id, workflow_id, contract_id, pay_type, effective_date, scope, amount, store_amounts, cap_amount, cap_unit, note, sync_status, created_by)
  values (wf.user_id, p_workflow, p_contract, p_pay_type, p_effective_date, p_scope, p_amount, p_store_amounts, p_cap_amount, coalesce(p_cap_unit, 'unknown'), p_note, 'pending', v_actor)
  returning id into v_id;
  v_payload := jsonb_build_object('setting_id', v_id, 'pay_type', p_pay_type, 'effective_date', p_effective_date, 'scope', p_scope, 'amount', p_amount, 'store_amounts', p_store_amounts, 'cap_amount', p_cap_amount, 'cap_unit', coalesce(p_cap_unit, 'unknown'));
  v_job := ui_job_enqueue(p_workflow, 'smaregi_commute', v_payload, v_actor, false);
  if coalesce(v_job ->> 'ok', 'false') = 'true' then
    update employee_commute_settings set ui_job_id = (v_job ->> 'job_id')::uuid, sync_status = 'queued', updated_at = now() where id = v_id;
  else
    -- 自動書き込みが未有効化（または作れない）: 確定値は残し、手動で管理画面に入れる（項目は manual_required）
    update employee_commute_settings set sync_status = 'manual', sync_error = v_job ->> 'error', updated_at = now() where id = v_id;
    perform onboarding_set_item(p_workflow, 'commute_set', 'manual_required', v_payload || jsonb_build_object('manual', true), v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, coalesce(v_job ->> 'error', '自動反映なし'));
  end if;
  insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, after) values (p_workflow, 'commute_set', 'commute.setting_saved', v_actor, case when auth.uid() is null then 'slack' else 'nippo' end, v_payload);
  return jsonb_build_object('ok', true, 'setting_id', v_id, 'job', v_job);
end $function$
;

-- 見回り（11-18 で足したもの）に、経路の自動検索を 1 行足す
create or replace function public.onboarding_auto_sweep()
returns jsonb language plpgsql security definer set search_path to 'public', 'net', 'extensions' as $$
declare
  c_fn   constant text := 'https://uuvsxzhpxtghojoubjcc.supabase.co/functions/v1/onboarding-notify';
  c_anon constant text := 'sb_publishable_MrwPJAx_Ws_fdRutprKCiQ_dg3wCiTr';
  w record; r jsonb; v_secret text; n int := 0; n_changed int := 0; v_ch boolean;
begin
  select value into v_secret from app_secrets where key = 'notify_slack_secret';
  for w in select id from onboarding_workflows where status = 'registering' order by created_at limit 50 loop
    n := n + 1; v_ch := false;
    begin
      if onboarding_slack_link_refresh(w.id) then v_ch := true; end if;
      perform onboarding_commute_auto_search(w.id);   -- 経路の検索を自動で始める（1 回だけ。表示の描き直しは検索の側が行う）
      r := onboarding_auto_enqueue(w.id);
      if coalesce((r ->> 'changed')::boolean, false) then v_ch := true; end if;
    exception when others then
      raise warning 'onboarding_auto_sweep（%）: %', w.id, sqlerrm;
    end;
    if v_ch then
      n_changed := n_changed + 1;
      if v_secret is not null and length(trim(v_secret)) > 0 then
        perform net.http_post(url := c_fn,
          headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', c_anon, 'Authorization', 'Bearer ' || c_anon, 'x-notify-secret', trim(v_secret)),
          body := jsonb_build_object('op', 'refresh', 'workflow_id', w.id), timeout_milliseconds := 60000);
      end if;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'checked', n, 'changed', n_changed);
end $$;
