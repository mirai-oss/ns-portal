-- 2026-11-28 採用の Slack 通知: 鶏武者 川崎店の応募は、担当者に加えて指定の1名にもメンションする（社長指示）
--   notice_mention_rules の targets の kind='user' に store_id を書けるようにした（その店舗のときだけ有効）。
--   戻し方: 2026-11-28_recruit_mention_store_user_rollback.sql
begin;

CREATE OR REPLACE FUNCTION public.notice_mention_targets(p_type text, p_scene text, p_store uuid DEFAULT NULL::uuid, p_task_assignees uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r notice_mention_rules%rowtype; t jsonb; v_ids uuid[] := '{}'; v_ex uuid[];
begin
  if not (hq_can_manage() or onboarding_is_service()) then raise exception '権限がありません'; end if;
  select * into r from notice_mention_rules where type_key = p_type and scene = p_scene;
  if p_store is not null and exists (select 1 from notice_store_holds h where h.type_key = p_type and h.store_id = p_store) then
    return jsonb_build_object('rule_found', r.id is not null, 'hold', true, 'targets', '[]'::jsonb, 'unlinked', '[]'::jsonb);
  end if;
  if r.id is null then return jsonb_build_object('rule_found', false, 'hold', false, 'targets', '[]'::jsonb, 'unlinked', '[]'::jsonb); end if;
  select coalesce(array_agg(x::uuid), '{}') into v_ex from jsonb_array_elements_text(coalesce((select value -> 'exclude_user_ids' from app_settings where key = 'notice'), '[]'::jsonb)) x;
  for t in select * from jsonb_array_elements(r.targets) loop
    if t ->> 'kind' = 'role' then
      v_ids := v_ids || coalesce((select array_agg(u.id) from users u where u.role in (select jsonb_array_elements_text(t -> 'roles'))), '{}');
    elsif t ->> 'kind' = 'store_role' and p_store is not null then
      v_ids := v_ids || coalesce((select array_agg(u.id) from users u join user_stores us on us.user_id = u.id where us.store_id = p_store and u.role in (select jsonb_array_elements_text(t -> 'roles'))), '{}');
    elsif t ->> 'kind' = 'store_team_leader' and p_store is not null then
      v_ids := v_ids || coalesce((select array_agg(u.id) from users u join team_stores ts on ts.team_id = u.team_id where ts.store_id = p_store and u.role = 'TEAM'), '{}');
    elsif t ->> 'kind' = 'user' and (t ->> 'store_id' is null or (t ->> 'store_id')::uuid = p_store) then   -- store_id があれば、その店舗のときだけ
      v_ids := v_ids || (t ->> 'user_id')::uuid;
    elsif t ->> 'kind' = 'task_assignee' then
      v_ids := v_ids || coalesce(p_task_assignees, '{}');
    end if;
  end loop;
  return (
    with c as (   -- 重複を 1 人に・退職/無効を除く・通知から外す設定の人を除く
      select distinct u.id, u.role, k.slack_user_id from users u left join user_slack k on k.user_id = u.id
       where u.id = any(v_ids) and u.is_active and u.deactivated_at is null and not (u.id = any(v_ex)))
    select jsonb_build_object('rule_found', true, 'hold', false,
      'targets', coalesce((select jsonb_agg(jsonb_build_object('user_id', c.id, 'slack_user_id', c.slack_user_id) order by c.id) from c where c.slack_user_id is not null), '[]'::jsonb),
      'unlinked', coalesce((select jsonb_agg(c.id order by c.id) from c where c.slack_user_id is null), '[]'::jsonb)));
end $function$;

update notice_mention_rules set targets = targets || jsonb_build_array(jsonb_build_object('kind','user','user_id','6ce6d3da-e910-4017-b924-7b5e293900b4','store_id','c3e8e08a-4816-43b6-aee6-8ee72cb912f4')), updated_at = now()
 where type_key = 'recruit' and scene in ('assignee','open') and not targets @> jsonb_build_array(jsonb_build_object('kind','user','user_id','6ce6d3da-e910-4017-b924-7b5e293900b4','store_id','c3e8e08a-4816-43b6-aee6-8ee72cb912f4'));
commit;
