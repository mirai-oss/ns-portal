-- =============================================================
-- 2026-11-18_onboarding_wage_approval.sql を外す（★実行は別途承認）
--   先に: 設定 onboarding_wage_approval.enabled を false に戻すこと（true のままだと止まる）。
--         Edge Function（onboarding-notify・slack-interact）は、設定が無い／false なら今までどおり動くので、先に戻さなくてもよい。
--   消えるもの: 入社時の賃金の確定依頼（承認待ち・承認済み・却下の記録と金額）と、その履歴。★ 先に控えを取ること。
--   消えないもの: 正式な賃金（employee_wage_settings）・入社登録（onboarding_*）・スマレジ側の変更の控え（wage_external_changes）・既存の申請（profile_change_requests）。
--   承認待ちが残っているときは止まる（先に、承認・却下・取り下げのどれかで片づける）。
-- =============================================================
do $$
begin
  if coalesce((select (s.value ->> 'enabled')::boolean from app_settings s where s.key = 'onboarding_wage_approval'), false) then
    raise exception '設定 onboarding_wage_approval.enabled が true です。先に false に戻してください';
  end if;
  if to_regclass('public.onboarding_wage_requests') is not null
     and exists (select 1 from onboarding_wage_requests q where q.status = 'pending') then
    raise exception '承認待ちの確定依頼が残っています。先に、承認・却下・取り下げのどれかで片づけてください';
  end if;
end $$;

-- 入社登録の項目「賃金」に残った、この機能の印（却下のあと入れ直し待ち・承認済みで反映待ち）を「未」に戻す。完了済みの項目は触らない
update public.onboarding_items i
   set state = 'pending', last_error = null, payload = i.payload - 'approval' - 'request_id' - 'rule' - 'reason' - 'requested_by' - 'decided_by', updated_at = now()
 where i.item_key = 'wage' and i.state in ('manual_required', 'running') and i.payload ? 'approval';

drop trigger if exists onboarding_wage_direct_guard on public.employee_wage_settings;
drop function if exists public.onboarding_wage_direct_guard();
drop function if exists public.onboarding_wage_status(uuid, uuid, boolean);
drop function if exists public.onboarding_wage_cancel(uuid, text, uuid);
drop function if exists public.onboarding_wage_decide(uuid, boolean, text, uuid, text);
drop function if exists public.onboarding_wage_submit(uuid, jsonb, uuid, text, boolean);
drop function if exists public.onboarding_wage_rule(uuid, jsonb, text);
drop function if exists public.onboarding_wage_notify(uuid, uuid, text);
drop function if exists public.onboarding_wage_apply(text, uuid, jsonb, uuid);
drop function if exists public.onboarding_wage_rows_norm(jsonb, text);
drop function if exists public.onboarding_wage_can(uuid, text);
drop function if exists public.onboarding_wage_actor(uuid);
drop function if exists public.onboarding_wage_cfg();
drop table if exists public.onboarding_wage_request_events;
drop table if exists public.onboarding_wage_requests;
delete from public.app_settings where key = 'onboarding_wage_approval';
