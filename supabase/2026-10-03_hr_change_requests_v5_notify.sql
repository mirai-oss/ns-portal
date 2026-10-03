-- ============================================================
-- 2026-10-03 担当B（nippo）— 退職申請 v5: 申請が出たらLINEで通知
-- 【状態】事前報告（ユーザー確認待ち・未適用）。前提: v1〜v4 適用済み
--
-- 【理由】ユーザー要望: 退職申請が出たら、LINE連携済みのマスター・社長・本部・チーム長にLINE通知する
--   （その店舗に関係する人だけ）。今はバッジだけで、気づけない。
-- 【現構造】通知の仕組みなし。申請の表（hr_change_requests）にLINE通知の記録列も無い
-- 【変更】
--   ① hr_change_requests に列 line_notified_at（通知を送った時刻＝1申請につき1回だけ送るための印）
--   ② 新RPC hr_claim_retire_notify(p_request)（service_role専用）: 承認待ち・申請から10分以内・未通知の申請だけを
--      「通知する」と印を付けて、通知文に使う情報と宛先(LINE連携済み)を返す。宛先=マスター・社長・本部は全店舗、
--      チーム長は担当チームの店舗＋自分の所属店舗がその申請の店舗に含まれる人。通知を送るのは新しいEdge Function
--      hr-retire-notify（フォーム・nippoの申請直後に呼ばれる）
-- 【影響】新規列1・新規RPC1・新規Edge Function1。既存の動きは変えない
-- 【migration】本ファイル（冪等）
-- 【rollback】drop function if exists public.hr_claim_retire_notify(uuid); alter table hr_change_requests drop column if exists line_notified_at;
--   Edge Function hr-retire-notify を削除
-- ============================================================

alter table hr_change_requests add column if not exists line_notified_at timestamptz;

create or replace function public.hr_claim_retire_notify(p_request uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r hr_change_requests%rowtype; v_store text; v_user text; v_rec text[];
begin
  update hr_change_requests
     set line_notified_at = now()
   where id = p_request and kind = 'retirement' and status = 'pending'
     and line_notified_at is null and requested_at > now() - interval '10 minutes'
  returning * into r;
  if r.id is null then
    return jsonb_build_object('ok', true, 'claimed', false, 'reason', '通知済み・対象外・時間切れのいずれか');
  end if;
  select name into v_store from stores where id = r.store_id;
  select name into v_user from users where id = r.user_id;
  select coalesce(array_agg(distinct u.line_user_id), array[]::text[]) into v_rec
    from users u
   where u.is_active and u.line_user_id is not null
     and (
       u.is_master or u.role in ('CEO', 'HQ')
       or (u.role = 'TEAM' and r.store_id = any(coalesce(team_store_ids(u.team_id), array[]::uuid[]) || coalesce(user_store_ids(u.id), array[]::uuid[])))
     );
  return jsonb_build_object(
    'ok', true, 'claimed', true,
    'store_name', coalesce(v_store, ''), 'user_name', coalesce(v_user, ''), 'effective_date', r.effective_date,
    'requester', coalesce((select name from users where id = r.requested_by), r.requester_name, ''),
    'note', r.note, 'recipients', to_jsonb(v_rec)
  );
end;
$function$;
revoke all on function public.hr_claim_retire_notify(uuid) from public, anon, authenticated;
grant execute on function public.hr_claim_retire_notify(uuid) to service_role;
