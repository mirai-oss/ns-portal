-- 2026-11-10 fix1: 通勤情報がワークフロー作成より前に保存されたとき（nippo は入社フォーム直後＝親メッセージ作成より前に RPC を呼ぶ）、
--   employee_commute.workflow_id が null のままで承認時の項目更新・監査が飛ばされていた（使い捨てテストで検出）。
--   対応: ①onboarding_start がワークフロー作成時に employee_commute.workflow_id を埋める ②onboarding_commute_decide は user_id からワークフローを引き直す
create or replace function public.onboarding_commute_decide(p_user uuid, p_decision text, p_fare integer, p_note text default null, p_actor uuid default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_actor uuid; c employee_commute%rowtype; v_before jsonb; v_wf uuid; v_via text;
begin
  v_actor := public.onboarding_resolve_actor(p_actor);
  if p_decision not in ('approved','rejected','person_review','hq_review') then raise exception '不正な判断です'; end if;
  select * into c from employee_commute where user_id = p_user for update;
  if c.user_id is null then raise exception '通勤情報がありません'; end if;
  if p_decision = 'approved' and (p_fare is null or p_fare < 0) then raise exception '承認する片道額を指定してください'; end if;
  v_wf := c.workflow_id;
  if v_wf is null then select id into v_wf from onboarding_workflows where user_id = p_user; end if;
  v_via := case when auth.uid() is null then 'slack' else 'nippo' end;
  v_before := jsonb_build_object('judgement', c.judgement, 'approved_fare', c.approved_fare);
  update employee_commute set judgement = p_decision, workflow_id = coalesce(workflow_id, v_wf),
         approved_fare = case when p_decision = 'approved' then p_fare else approved_fare end,
         approved_by = case when p_decision = 'approved' then v_actor else approved_by end,
         approved_at = case when p_decision = 'approved' then now() else approved_at end,
         approve_note = coalesce(p_note, approve_note), updated_at = now()
   where user_id = p_user;
  if v_wf is not null then
    insert into onboarding_events(workflow_id, item_key, kind, actor_id, via, before, after)
    values (v_wf, 'commute_check', 'commute.decided', v_actor, v_via, v_before, jsonb_build_object('judgement', p_decision, 'approved_fare', p_fare, 'note', p_note));
    if p_decision = 'approved' then
      perform onboarding_set_item(v_wf, 'commute_check', 'completed', jsonb_build_object('approved_fare', p_fare, 'verified', null), v_actor, v_via, null);
    elsif p_decision = 'rejected' then
      perform onboarding_set_item(v_wf, 'commute_check', 'manual_required', jsonb_build_object('rejected', true), v_actor, v_via, coalesce(p_note, '本部が差し戻し'));
    end if;
  end if;
  return jsonb_build_object('ok', true, 'judgement', p_decision, 'approved_fare', p_fare, 'workflow_id', v_wf);
end $$;

-- onboarding_start: 作成時に employee_commute / employee_commute_settings / employee_tax_settings の workflow_id を埋める（既存行があれば）
-- 既存の関数本体は長いため、後処理だけを別関数にしてトリガーで呼ぶ（onboarding_start 自体は変えない）
create or replace function public.onboarding_link_commute_on_insert()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.user_id is not null then
    update employee_commute set workflow_id = new.id, updated_at = now() where user_id = new.user_id and workflow_id is null;
    update employee_commute_settings set workflow_id = new.id, updated_at = now() where user_id = new.user_id and workflow_id is null;
    update employee_tax_settings set workflow_id = new.id, updated_at = now() where user_id = new.user_id and workflow_id is null;
  end if;
  return null;
end $$;
drop trigger if exists trg_onboarding_link_commute on public.onboarding_workflows;
create trigger trg_onboarding_link_commute after insert on public.onboarding_workflows for each row execute function public.onboarding_link_commute_on_insert();
-- 既存行の補正（今はテスト行だけ）
update public.employee_commute c set workflow_id = w.id from public.onboarding_workflows w where w.user_id = c.user_id and c.workflow_id is null;
