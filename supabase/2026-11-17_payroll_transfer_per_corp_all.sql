-- 除外した人・出力の印・口座の控え・本部タスクを、すべて法人別に分ける（2026-11-17・ユーザー指示「基本的に全部法人別に」）
--
-- 背景: 振込データの出力まわりの安全の仕組み（除外した人 payroll_transfer_holds・出力の印 payroll_transfer_export_tokens・口座の控え・
--       【振込漏れ注意】タスク）は、「対象月」だけで動いていた。同じ月にトーホーと LiveGate が出力すると、除外・控え・完了の止め方が法人をまたいで混ざる。
-- 直し（法人を渡さない古い画面・処理は、今までと同じ動き＝トーホーまたは「全法人」）:
--   表: payroll_transfer_export_tokens／payroll_transfer_holds に corporation_id（既定＝トーホー）を足す（既存の印9件はトーホー・除外は0件）。
--   payroll_corp_users(月, 法人) … その月にその法人の契約（sf_payroll_sync→smaregi_contracts）で給与がある人（新規）
--   pay_transfer_pending_holds(月, 法人=null) … 法人を渡すと、その法人の人だけ（null＝全法人）
--   hr_payroll_transfer_prepare(月, 法人=null) … 印・口座の控え・除外の情報を法人別に（null＝トーホー）
--   payroll_transfer_schedule_guard／_wage_guard／_after … 印は法人も一致が必要／賃金の停止は「この法人」の分だけ／除外・口座の控えはこの法人の人だけ・法人つきで記録
--   pay_transfer_hold_task_sync(月, 法人=null) … 【振込漏れ注意】タスクを法人ごとに（法人別の「給与振込確認」の名簿に載せる。null＝除外のある法人ごとに回す）
--   payroll_transfer_confirm_step_guard … タスクの法人の除外だけで完了を止める
--   payroll_transfer_batch_freeze … 候補から外す除外は、その法人の分だけ
-- 戻し方: 2026-11-17_payroll_transfer_per_corp_all_rollback.sql
-- 注意: pay_transfer_pending_holds・hr_payroll_transfer_prepare・pay_transfer_hold_task_sync は引数が増えるため、古い定義を消してから作り直す（呼び出し側は引数なしの法人でも動く）。

alter table public.payroll_transfer_export_tokens add column if not exists corporation_id uuid not null default '9f3f5239-d346-42b9-86cf-144e246cebeb'::uuid references public.corporations(id);
alter table public.payroll_transfer_holds add column if not exists corporation_id uuid not null default '9f3f5239-d346-42b9-86cf-144e246cebeb'::uuid references public.corporations(id);

create or replace function public.payroll_corp_users(p_ym text, p_corp uuid) returns table(user_id uuid)
language sql stable security definer set search_path to 'public' as $f$
  select distinct sp.user_id from sf_payroll_sync sp join smaregi_contracts sc on sc.contract_id = sp.contract_id
   where sp.year_month = p_ym and sc.corporation_id = p_corp
$f$;
revoke all on function public.payroll_corp_users(text, uuid) from public, anon;
grant execute on function public.payroll_corp_users(text, uuid) to authenticated, service_role;

drop function if exists public.pay_transfer_pending_holds(text);
drop function if exists public.hr_payroll_transfer_prepare(text);
drop function if exists public.pay_transfer_hold_task_sync(text);

CREATE OR REPLACE FUNCTION public.pay_transfer_pending_holds(p_year_month text, p_corp uuid DEFAULT NULL::uuid)
 RETURNS TABLE(user_id uuid, request_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select q.user_id, q.id from profile_change_requests q
   where q.field = 'bank_account' and q.status = 'pending' and (q.effective_year_month is null or q.effective_year_month <= p_year_month)
     and (p_corp is null or q.user_id in (select u.user_id from public.payroll_corp_users(p_year_month, p_corp) u))
     -- いま銀行振込の口座が登録されている人だけ（口座が未登録・現金手渡しの人は、もともと振込データに入らない＝従来どおりの扱い）
     and exists (select 1 from payroll_bank_accounts b where b.user_id = q.user_id and coalesce(public.payroll_month_method(b.user_id, p_year_month), 'bank_transfer') <> 'cash')
     and not exists (select 1 from payroll_transfer_schedule t where t.year_month = p_year_month
                      and t.created_at < coalesce((select (value ->> 'transfer_guard_since')::timestamptz from app_settings where key = 'employee_change'), '-infinity'::timestamptz))
     and not exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = p_year_month and s.user_id = q.user_id)
  union all
  -- 2026-11-12 開発 2: 未承認の賃金変更がある人（関所が有効のときだけ。口座変更で既に外す人は重ねない）
  select w.user_id, null::uuid from payroll_wage_holds(p_year_month) w
   where (p_corp is null or w.user_id in (select u.user_id from public.payroll_corp_users(p_year_month, p_corp) u))
     and exists (select 1 from payroll_bank_accounts b where b.user_id = w.user_id and coalesce(public.payroll_month_method(b.user_id, p_year_month), 'bank_transfer') <> 'cash')
     and not exists (select 1 from payroll_transfer_schedule t where t.year_month = p_year_month
                      and t.created_at < coalesce((select (value ->> 'transfer_guard_since')::timestamptz from app_settings where key = 'employee_change'), '-infinity'::timestamptz))
     and not exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = p_year_month and s.user_id = w.user_id)
     and not exists (select 1 from profile_change_requests q2 where q2.user_id = w.user_id and q2.field = 'bank_account' and q2.status = 'pending' and (q2.effective_year_month is null or q2.effective_year_month <= p_year_month))
$function$
;

CREATE OR REPLACE FUNCTION public.hr_payroll_transfer_prepare(p_year_month text, p_corp uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_applied integer := 0; v_snap jsonb; v_token uuid; v_hold uuid[]; v_corp uuid := coalesce(p_corp, '9f3f5239-d346-42b9-86cf-144e246cebeb'::uuid);   -- 法人を渡さない古い画面はトーホー
begin
  if not (invoice_can_access() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  if p_year_month !~ '^\d{4}-\d{2}$' then raise exception '月（YYYY-MM）が不正です'; end if;
  if pay_transfer_paused() then   -- ⑤ 切り替え作業中: 何もしないで「停止中」だけ返す
    return jsonb_build_object('ok', true, 'paused', true, 'year_month', p_year_month, 'attention', '[]'::jsonb, 'hold', '[]'::jsonb, 'ready', '[]'::jsonb, 'hold_records', '[]'::jsonb);
  end if;
  perform pay_transfer_holds_wage_refresh(p_year_month);   -- 2026-11-12 開発 2: 賃金の保留が解けた人を「その人の分が未出力」に進める
  begin v_applied := hr_apply_due_bank_changes_internal();
  exception when others then perform employee_change_log_error('payroll_transfer_prepare', 'apply_due', null, sqlerrm); end;
  -- 口座の控えは、登録口座を読める人（マスター・本部）にだけ返す
  if (is_profile_approver() or onboarding_is_service()) and exists (select 1 from payroll_transfer_schedule where year_month = p_year_month and corporation_id = v_corp and export_ok is not false) then
    select jsonb_object_agg(s.user_id, s.account || jsonb_build_object('user_id', s.user_id, '_source', s.source)) into v_snap from payroll_transfer_account_snapshots s where s.year_month = p_year_month and s.user_id in (select u.user_id from public.payroll_corp_users(p_year_month, v_corp) u);
  end if;
  -- ⑥ 出力の印を発行（この呼び出しのあとの出力 1 回ぶん。除外するよう伝えた人を控える）
  select coalesce(array_agg(h.user_id), '{}') into v_hold from pay_transfer_pending_holds(p_year_month, v_corp) h;
  if auth.uid() is not null then
    delete from payroll_transfer_export_tokens where issued_at < now() - interval '2 days';
    insert into payroll_transfer_export_tokens(year_month, user_id, hold_users, corporation_id) values (p_year_month, auth.uid(), v_hold, v_corp) returning token into v_token;
  end if;
  return jsonb_build_object('ok', true, 'paused', false, 'export_token', v_token, 'year_month', p_year_month, 'corporation_id', v_corp, 'state', pay_run_state(p_year_month), 'pay_date', pay_run_date(p_year_month), 'applied', v_applied,
    'snapshot', v_snap, 'attention', hr_pay_change_attention_internal(p_year_month),
    -- hold=この回の振込データに入れてはいけない人（未承認の口座変更が影響）／ready=除外していたが申請が片付いた人（その人の分を出す）
    'hold', (select coalesce(jsonb_agg(jsonb_build_object('user_id', h.user_id, 'user_name', (select name from users u where u.id = h.user_id), 'request_id', h.request_id, 'reason', case when h.request_id is null then 'wage_unapproved' else 'bank_change' end)), '[]'::jsonb) from pay_transfer_pending_holds(p_year_month, v_corp) h),
    -- 2026-11-12 開発 2: 未承認の賃金変更の関所（止めている法人・人ごとの保留の人数）。関所が無効なら enabled=false
    'wage_guard', payroll_wage_guard_summary(p_year_month),
    'ready', (select coalesce(jsonb_agg(jsonb_build_object('user_id', h.user_id, 'user_name', (select name from users u where u.id = h.user_id))), '[]'::jsonb) from payroll_transfer_holds h where h.year_month = p_year_month and h.corporation_id = v_corp and h.status = 'ready'),
    'transfer_pending_mode', coalesce((select value ->> 'transfer_pending_mode' from app_settings where key = 'employee_change'), 'exclude'),
    -- 除外の記録（誰が・なぜ・いまの状況）。振込が済んだもの（done）も履歴として返す
    'hold_records', (select coalesce(jsonb_agg(jsonb_build_object('user_id', h.user_id, 'user_name', (select name from users u where u.id = h.user_id), 'status', h.status,
                       'reason', pay_transfer_hold_reason_text(h.reasons), 'reasons', to_jsonb(h.reasons),
                       'status_label', case h.status when 'held' then case when 'wage_unapproved' = any(h.reasons) then '除外中（賃金変更の確認・是正、または社長の承認による例外解除が必要）' else '除外中（申請の承認・却下が必要）' end when 'ready' then '申請は処理済み・この人の分の振込データが未出力' else '振込データ出力済み' end,
                       'request_status', (select q.status from profile_change_requests q where q.id = h.request_id), 'excluded_at', h.created_at, 'resolved_at', h.resolved_at, 'done_at', h.done_at) order by h.created_at), '[]'::jsonb)
                      from payroll_transfer_holds h where h.year_month = p_year_month and h.corporation_id = v_corp),
    'bank_approval_required', coalesce((select (value ->> 'bank_approval_required')::boolean from app_settings where key = 'employee_change'), false));
end $function$
;

CREATE OR REPLACE FUNCTION public.pay_transfer_hold_task_sync(p_year_month text, p_corp uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_task uuid; v_step uuid; h record; v_item uuid; v_assignee uuid; v_open int; v_cstep uuid; v_title text; v_cname text; v_cc uuid;
begin
  -- 2026-11-17: 法人を渡さない呼び出し（古い画面・ほかの処理）は、除外の記録がある法人ごとに回す
  if p_corp is null then
    for v_cc in select distinct x.corporation_id from payroll_transfer_holds x where x.year_month = p_year_month loop
      v_task := public.pay_transfer_hold_task_sync(p_year_month, v_cc);
    end loop;
    return v_task;
  end if;
  select case when c.corp_code = 'toho' then '' else '・' || c.name end into v_cname from corporations c where c.id = p_corp;
  -- 既存の「給与振込確認」タスク（出力のたびに作られる／更新される）。除外した人を「未振込」として載せる
  select st.id into v_cstep from transfer_confirm_task_links l join hq_tasks k on k.id = l.hq_task_id join hq_task_steps st on st.task_id = k.id
   where l.kind = 'payroll' and l.scope_key = public.payroll_task_scope(p_year_month, p_corp) and k.deleted_at is null order by st.sort_order limit 1;
  for h in select * from payroll_transfer_holds where year_month = p_year_month and corporation_id = p_corp loop
    v_title := '⚠️ 未振込: ' || coalesce((select name from users where id = h.user_id), '—') || 'さん（' || pay_transfer_hold_reason_label(h.reasons) || 'で除外）';
    if v_cstep is not null then
      if h.status in ('held', 'ready') and not exists (select 1 from hq_step_checklist_items c where c.step_id = v_cstep and c.title = v_title) then
        insert into hq_step_checklist_items(step_id, title, sort_order) values (v_cstep, v_title, 5);
      elsif h.status = 'done' then
        update hq_step_checklist_items set checked_at = now(), checked_by = auth.uid() where step_id = v_cstep and title = v_title and checked_at is null;
      end if;
    end if;
  end loop;
  select hq_task_id into v_task from payroll_transfer_holds where year_month = p_year_month and corporation_id = p_corp and hq_task_id is not null limit 1;
  if v_task is null then
    if not exists (select 1 from payroll_transfer_holds where year_month = p_year_month and corporation_id = p_corp and status in ('held', 'ready')) then return null; end if;
    select u.id into v_assignee from users u where u.name in ('青山純', '原　美香', '齋藤　隆治') and u.is_active order by array_position(array['青山純', '原　美香', '齋藤　隆治'], u.name) limit 1;
    insert into hq_tasks(title, corp, freq, target_date, due_date, notes, description, visibility, created_by, is_urgent)
    values ('【振込漏れ注意】' || p_year_month || ' 月分の給与振込' || coalesce(v_cname, '') || ': ' || case when exists (select 1 from payroll_transfer_holds x where x.year_month = p_year_month and x.corporation_id = p_corp and 'wage_unapproved' = any(x.reasons)) then '確認待ちで除外した人がいます' else '口座変更の確認待ちで除外した人がいます' end, 'トーホー', 'once', current_date, least(pay_run_date(p_year_month), current_date + 3), '',
            p_year_month || ' 月分（' || pay_run_date(p_year_month) || ' 支給）の振込データから、口座変更の申請が承認待ちの人を除外しました。このままでは、その人に振り込まれません。'
            || E'\n' || '① 従業員ページで口座変更の申請を承認（どの支給回からかを選ぶ）または却下する ② 振込画面で「除外していた人の分を出力」して振り込む。'
            || case when exists (select 1 from payroll_transfer_holds x where x.year_month = p_year_month and x.corporation_id = p_corp and 'wage_unapproved' = any(x.reasons)) then E'\n' || '※ 未承認の賃金変更（スマレジで直接変更・承認待ちの申請）が理由の人は、従業員ページで確認・是正してください。是正できない事情があるときは、社長の承認による例外解除が必要です。金額はここには表示しません。' else '' end
            || E'\n' || '②まで終わると、このタスクのチェックは自動で付きます。口座番号などはここには表示しません。', 'all', auth.uid(), true)
    returning id into v_task;
    insert into hq_task_steps(task_id, title, assignee_id, sort_order, kind, due_date) values (v_task, '除外した人の申請を処理し、その人の分の振込データを出力する', v_assignee, 10, 'step', least(pay_run_date(p_year_month), current_date + 3)) returning id into v_step;
    insert into hq_task_activity(task_id, actor_id, kind, detail) values (v_task, auth.uid(), 'create', '振込データの出力で除外した人がいるため自動作成');
  else
    select id into v_step from hq_task_steps where task_id = v_task order by sort_order limit 1;
  end if;
  for h in select * from payroll_transfer_holds where year_month = p_year_month and corporation_id = p_corp loop
    if h.checklist_item_id is null then
      insert into hq_step_checklist_items(step_id, title, sort_order) values (v_step, coalesce((select name from users where id = h.user_id), '—') || 'さん', 10) returning id into v_item;
      update payroll_transfer_holds set hq_task_id = v_task, checklist_item_id = v_item where year_month = h.year_month and user_id = h.user_id;
      h.checklist_item_id := v_item;
    end if;
    if h.status = 'done' then update hq_step_checklist_items set checked_at = coalesce(checked_at, now()), checked_by = coalesce(checked_by, auth.uid()) where id = h.checklist_item_id; end if;
  end loop;
  select count(*) into v_open from payroll_transfer_holds where year_month = p_year_month and corporation_id = p_corp and status in ('held', 'ready');
  if v_open = 0 then update hq_task_steps set completed_at = now(), completed_by = auth.uid() where task_id = v_task and completed_at is null; end if;
  return v_task;
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_transfer_schedule_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_names text; v_tok payroll_transfer_export_tokens%rowtype; v_valid boolean := false;
begin
  if coalesce(current_setting('employee_change.schedule_internal', true), '') <> '' then return new; end if;   -- 【要確認】タスクの印を付けるだけの内部の更新
  if pay_transfer_paused() then raise exception '切り替え作業中のため、振込 CSV の出力は一時停止しています。この CSV は使わないでください。再開の連絡のあと、画面を再読み込みしてから出力してください'; end if;
  if new.export_token is not null and (tg_op = 'INSERT' or new.export_token is distinct from old.export_token) then
    select * into v_tok from payroll_transfer_export_tokens t where t.token = new.export_token and t.year_month = new.year_month and t.corporation_id = new.corporation_id and t.user_id = auth.uid() and t.used_at is null and t.issued_at > now() - interval '2 hours' for update;
    v_valid := v_tok.token is not null;
  end if;
  if not v_valid then
    -- 古い画面・直接の API からの出力。記録は残すが、確定としては扱わない（控え・除外の処理をしない）。後処理で【要確認】のタスクを出す
    new.export_ok := case when tg_op = 'UPDATE' then old.export_ok else false end;
    new.export_token := case when tg_op = 'UPDATE' then old.export_token else null end;
    new.invalid_export_at := clock_timestamp();
    return new;
  end if;
  if coalesce((select value ->> 'transfer_pending_mode' from app_settings where key = 'employee_change'), 'exclude') = 'block_all' then
    select string_agg((select name from users u where u.id = h.user_id), '、') into v_names from pay_transfer_pending_holds(new.year_month, new.corporation_id) h;
    if v_names is not null then raise exception '% 月分の振込データは確定できません。口座変更の申請が承認待ちの人がいます（%）。承認または却下してから出力してください', new.year_month, v_names; end if;
  end if;
  new.export_ok := true;   -- 印を「使用済み」にするのは後処理で（画面の記録は「追加 → 既にあれば更新」の 2 段階で、前処理が 2 回走るため）
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_transfer_schedule_wage_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_stop jsonb; v_holds uuid[]; v_names text;
begin
  if coalesce(current_setting('employee_change.schedule_internal', true), '') <> '' then return new; end if;
  if not payroll_wage_guard_enabled() then return new; end if;
  if not (new.export_ok is true and new.export_token is not null and (tg_op = 'INSERT' or new.export_token is distinct from old.export_token)) then return new; end if;
  -- 2026-11-17: 止めているのが「この法人」のときだけ止める（ほかの法人の停止で、この法人の出力を止めない）
  select coalesce(jsonb_agg(s), '[]'::jsonb) into v_stop from jsonb_array_elements(payroll_wage_stop(new.year_month)) s where (s ->> 'corporation_id')::uuid = new.corporation_id;
  if jsonb_array_length(v_stop) > 0 then
    raise exception '% 月分の振込データは出力できません（停止中）。%。スマレジの賃金の照合を実行してからやり直してください。照合できない事情があるときは、社長の承認による例外解除が必要です。この CSV は使わないでください', new.year_month, payroll_wage_stop_text(v_stop);
  end if;
  select t.hold_users into v_holds from payroll_transfer_export_tokens t where t.token = new.export_token;
  select string_agg(coalesce((select name from users u where u.id = h.user_id), '—') || 'さん', '、') into v_names
    from pay_transfer_pending_holds(new.year_month, new.corporation_id) h where h.request_id is null and not (h.user_id = any(coalesce(v_holds, '{}')));
  if v_names is not null then
    raise exception '% 月分の振込データは出力できません。未承認の賃金変更がある人（%）が除外されていません。画面を再読み込みしてからやり直してください。この CSV は使わないでください', new.year_month, v_names;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_transfer_schedule_after()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_new int := 0; v_on boolean; v_holds uuid[];
begin
  if coalesce(current_setting('employee_change.schedule_internal', true), '') <> '' then return null; end if;   -- 【要確認】タスクの印を付けるだけの内部の更新
  begin
    if new.invalid_export_at is not null and (tg_op = 'INSERT' or new.invalid_export_at is distinct from old.invalid_export_at) then
      -- ⑥ 印の無い出力: 確定として扱わない（控え・除外の処理をしない）。本部に知らせる
      perform pay_transfer_invalid_export_task(new.year_month);
      return null;
    end if;
    if new.export_ok is not true then return null; end if;
    if exists (select 1 from payroll_transfer_export_tokens t where t.token = new.export_token and t.used_at is not null) then return null; end if;   -- 同じ印では 1 回だけ処理する
    update payroll_transfer_export_tokens set used_at = now() where token = new.export_token;
    -- ① 画面に「除外する」と伝えた人（出力の印に控えてある）を、除外として記録。その後に申請が片付いていれば「その人の分が未出力」から始める
    select t.hold_users into v_holds from payroll_transfer_export_tokens t where t.token = new.export_token;
    with ins as (
      insert into payroll_transfer_holds(year_month, user_id, request_id, status, resolved_at, corporation_id)
      select new.year_month, u.id,
             (select q.id from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' order by (q.status = 'pending') desc, q.requested_at desc limit 1),
             case when exists (select 1 from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' and q.status = 'pending') then 'held' else 'ready' end,
             case when exists (select 1 from profile_change_requests q where q.user_id = u.id and q.field = 'bank_account' and q.status = 'pending') then null else now() end,
             new.corporation_id
        from unnest(coalesce(v_holds, '{}')) as u(id)
       where not exists (select 1 from payroll_transfer_account_snapshots sn where sn.year_month = new.year_month and sn.user_id = u.id)
      on conflict (year_month, user_id) do update set request_id = excluded.request_id, status = excluded.status, resolved_at = excluded.resolved_at where payroll_transfer_holds.status <> excluded.status and payroll_transfer_holds.status <> 'done'
      returning 1)
    select count(*) into v_new from ins;
    perform pay_transfer_holds_wage_fix(new.year_month, coalesce(v_holds, '{}'));   -- 2026-11-12 開発 2: 除外の理由（口座変更／未承認の賃金変更）を記録
    -- ② それ以外の人の口座の控え（最初の出力時点のもの。出し直しても自動では変えない。出力後に口座を登録した人・除外が解けた人だけ足される）
    insert into payroll_transfer_account_snapshots(year_month, user_id, account, taken_by)
    select new.year_month, b.user_id, to_jsonb(b) - 'created_at' - 'updated_at' - 'updated_by' - 'user_id', auth.uid() from payroll_bank_accounts b
     where not (b.user_id = any(coalesce(v_holds, '{}')))
      and b.user_id in (select cu.user_id from public.payroll_corp_users(new.year_month, new.corporation_id) cu)   -- 2026-11-17: この法人の人だけ（法人ごとの出力時点の口座を控える）
    on conflict (year_month, user_id) do nothing;
    -- ③ 除外が解けていた人（ready）は、今回の出力で振込データに入った＝完了
    update payroll_transfer_holds h set status = 'done', done_at = now() where h.year_month = new.year_month and h.corporation_id = new.corporation_id and h.status = 'ready' and not (h.user_id = any(coalesce(v_holds, '{}')))
       and exists (select 1 from payroll_transfer_account_snapshots s where s.year_month = h.year_month and s.user_id = h.user_id);
    perform pay_transfer_hold_task_sync(new.year_month, new.corporation_id);
    if v_new > 0 then
      select coalesce((value ->> 'pay_request_notify_enabled')::boolean, false) into v_on from app_settings where key = 'employee_change';
      if coalesce(v_on, false) then perform pay_change_notify_op('transfer_hold', jsonb_build_object('year_month', new.year_month)); end if;
    end if;
    perform hr_apply_due_bank_changes_internal();   -- この回の出力が済んだので、次の回からの予約を反映
  exception when others then perform employee_change_log_error('payroll_transfer_schedule', lower(tg_op), null, sqlerrm);
  end;
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_transfer_confirm_step_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ym text; v_names text; v_scope text; v_corp uuid;
begin
  if not (new.completed_at is not null and old.completed_at is null) then return new; end if;
  begin
    select l.scope_key into v_scope from transfer_confirm_task_links l where l.kind = 'payroll' and l.hq_task_id = new.task_id limit 1;
    v_ym := split_part(v_scope, ':', 1);
    -- 2026-11-17: タスクの法人（scope_key の ':' のうしろ＝法人コード。無ければトーホー）の除外だけを見る
    v_corp := coalesce((select c.id from corporations c where c.corp_code = nullif(split_part(v_scope, ':', 2), '')), '9f3f5239-d346-42b9-86cf-144e246cebeb'::uuid);
    if v_ym is not null and v_ym <> '' then
      select string_agg((select name from users u where u.id = h.user_id) || 'さん', '、') into v_names from payroll_transfer_holds h where h.year_month = v_ym and h.corporation_id = v_corp and h.status in ('held', 'ready');
    end if;
  exception when others then v_names := null;   -- 判定そのものの失敗では、本部タスクの操作を止めない
  end;
  if v_names is not null then
    raise exception '% 月分の給与振込は、まだ完了にできません。確認待ち（口座変更の承認待ち・未承認の賃金変更）で振込データから除外した人の振込が済んでいません（%）。申請・賃金変更の確認を済ませ、振込画面で「除外していた人の分を出力」して振り込んでから完了にしてください', v_ym, v_names;
  end if;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.payroll_transfer_batch_freeze(p_year_month text, p_corp_id uuid, p_scheduled_date date DEFAULT NULL::date, p_skip_unready boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_date date; v_seq integer; v_batch uuid; v_existing uuid; v_cand jsonb; v_ready jsonb;
  v_count integer := 0; v_total numeric := 0; v_hash text; v_unready integer := 0;
begin
  if not public.payroll_pay_can() then raise exception '権限がありません'; end if;
  if p_year_month is null or p_year_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception '月（YYYY-MM）が不正です'; end if;
  if p_corp_id is null then raise exception '法人が指定されていません'; end if;
  perform pg_advisory_xact_lock(hashtext('payroll_transfer_batch:' || p_year_month || ':' || p_corp_id::text));   -- 同時に押されても 1 つだけ

  select b.id into v_existing from payroll_transfer_batches b
   where b.year_month = p_year_month and b.corporation_id = p_corp_id and b.batch_kind = 'regular';
  if v_existing is not null then
    return jsonb_build_object('ok', true, 'already', true, 'batch_id', v_existing);
  end if;

  v_date := coalesce(p_scheduled_date, (select t.scheduled_date from payroll_transfer_schedule t where t.year_month = p_year_month and t.corporation_id = p_corp_id));
  if v_date is null then raise exception '振込指定日が決まっていません'; end if;

  -- 予定者の候補（まだどのバッチにも入っていない人）
  select coalesce(jsonb_agg(jsonb_build_object('user_id', c.user_id, 'amount', c.amt, 'account', c.account) order by c.user_id), '[]'::jsonb)
    into v_cand
    from (
      select sp.user_id, round(sum(sp.net_pay)) as amt,
             (select m.account from payroll_month_payments m
               where m.user_id = sp.user_id and m.year_month = p_year_month and m.status = 'fixed' and m.method = 'bank_transfer') as account
        from sf_payroll_sync sp
        join smaregi_contracts sc on sc.contract_id = sp.contract_id
       where sp.year_month = p_year_month and sc.corporation_id = p_corp_id
         and public.payroll_month_method(sp.user_id, p_year_month) = 'bank_transfer'
         and not exists (select 1 from sf_payroll_hidden h where h.user_id = sp.user_id and h.year_month = p_year_month)
         and not exists (select 1 from public.pay_transfer_pending_holds(p_year_month, p_corp_id) ph where ph.user_id = sp.user_id)
         and not exists (select 1 from payroll_transfer_batch_lines l0
                          where l0.year_month = p_year_month and l0.corporation_id = p_corp_id and l0.user_id = sp.user_id)
       group by sp.user_id
      having round(sum(sp.net_pay)) > 0
    ) c;

  -- 振込先の控えが使える人だけを残す
  select coalesce(jsonb_agg(e.value order by e.value ->> 'user_id'), '[]'::jsonb) into v_ready
    from jsonb_array_elements(v_cand) e
   where jsonb_typeof(e.value -> 'account') = 'object'
     and public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                       e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number') is not null
     and public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana') <> '';
  v_unready := jsonb_array_length(v_cand) - jsonb_array_length(v_ready);
  if v_unready > 0 and not coalesce(p_skip_unready, false) then
    return jsonb_build_object('ok', false, 'reason', 'unready', 'unready_count', v_unready,
                              'message', '振込先の控え（給料確定のときの口座）が無い人がいます。給料確定・口座を確かめてから、もう一度固めてください');
  end if;

  select count(*), coalesce(sum((e.value ->> 'amount')::numeric), 0),
         encode(sha256(convert_to(coalesce(string_agg(concat_ws('|', e.value ->> 'user_id', e.value ->> 'amount',
                  public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                                e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number'),
                  public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana')), E'\n' order by e.value ->> 'user_id'), ''), 'UTF8')), 'hex')
    into v_count, v_total, v_hash
    from jsonb_array_elements(v_ready) e;
  if v_count = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_targets', 'unready_count', v_unready, 'message', '固める対象の人がいません');
  end if;

  select coalesce(max(b.batch_seq), 0) + 1 into v_seq from payroll_transfer_batches b where b.year_month = p_year_month and b.corporation_id = p_corp_id;

  perform set_config('payroll.recon_ok', '1', true);
  insert into payroll_transfer_batches(year_month, corporation_id, batch_seq, batch_kind, scheduled_date, expected_count, expected_total, lines_hash, frozen_by)
  values (p_year_month, p_corp_id, v_seq, 'regular', v_date, v_count, v_total, v_hash, auth.uid())
  returning id into v_batch;
  insert into payroll_transfer_batch_lines(batch_id, year_month, corporation_id, user_id, amount, account, acct_key, kana_norm, account_source)
  select v_batch, p_year_month, p_corp_id, (e.value ->> 'user_id')::uuid, (e.value ->> 'amount')::numeric, e.value -> 'account',
         public.payroll_recon_acct_key(e.value -> 'account' ->> 'bank_code', e.value -> 'account' ->> 'branch_code',
                                       e.value -> 'account' ->> 'account_type', e.value -> 'account' ->> 'account_number'),
         public.payroll_recon_kana_norm(e.value -> 'account' ->> 'account_holder_kana'), 'month'
    from jsonb_array_elements(v_ready) e;
  perform public.payroll_recon_log(v_batch, null, 'frozen', null, 'planned', 'human', null,
                                   jsonb_build_object('batch_seq', v_seq, 'batch_kind', 'regular', 'count', v_count, 'scheduled_date', v_date, 'skipped_unready', v_unready));
  perform public.payroll_recon_eval(v_batch, 'auto_bank');   -- 銀行のデータが先に取り込まれていた場合に備えて、すぐ照合する（無ければ何も変わらない）
  perform set_config('payroll.recon_ok', '', true);

  return jsonb_build_object('ok', true, 'already', false, 'batch_id', v_batch, 'batch_seq', v_seq, 'batch_kind', 'regular', 'count', v_count, 'skipped_unready', v_unready);
end $function$;

revoke all on function public.pay_transfer_pending_holds(text, uuid) from public, anon;
grant execute on function public.pay_transfer_pending_holds(text, uuid) to authenticated, service_role;
revoke all on function public.hr_payroll_transfer_prepare(text, uuid) from public, anon;
grant execute on function public.hr_payroll_transfer_prepare(text, uuid) to authenticated, service_role;
revoke all on function public.pay_transfer_hold_task_sync(text, uuid) from public, anon;
grant execute on function public.pay_transfer_hold_task_sync(text, uuid) to authenticated, service_role;
