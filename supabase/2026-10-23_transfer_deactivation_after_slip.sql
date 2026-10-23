-- ============================================================
-- 2026-10-23 担当B（nippo）— 移籍者の旧契約(トーホー)のスマレジ打刻OFFを、源泉徴収票の工程が済んでから行う
-- 【状態】事前報告（ユーザー確認待ち・未適用）。前提: 2026-10-17_hr_change_requests_v6_transfer.sql 適用済み
--
-- 【理由】ユーザー確定（司令塔経由）: 移籍者の利用停止は「源泉徴収票アップ→退職手続きタスク完了→自動停止」の既存ロジックのまま。
--   ただし移籍者は本人がLiveGateで働き続けるため、停止の中身は旧契約(トーホー)のスマレジ打刻OFFだけ。
--   管理システムのアカウント(users.is_active)は停止せず、employee_profiles.termination_dateにも日付を入れない（今までどおり）。
-- 【現構造】hr_due_transfer_deactivations は「旧契約の終了日（開始日の前日）を過ぎた承認済みの移籍」を毎朝の自動処理(hr-termination-apply.yml)へ返し、
--   旧契約の打刻OFFを行う。源泉徴収票の工程を待たない（退職の自動停止は待つ）
-- 【変更】hr_due_transfer_deactivations に「源泉徴収票の工程が済んでいる（またはその人の退職手続きタスクが無い）」条件を足す＝
--   hr_slip_pending(user)=false のときだけ返す。他は同じ（既存の行・退職の流れは変えない）
-- 【影響】移籍者の旧契約の打刻OFFが、退職手続きタスクの源泉徴収票の工程（または従業員編集からの源泉徴収票の登録）が済むまで待たされる。
--   アカウント・所属・termination_date は従来どおり触らない
-- 【migration】本ファイル（create or replace・冪等）
-- 【rollback】2026-10-17_hr_change_requests_v6_transfer.sql の hr_due_transfer_deactivations を再実行
-- ============================================================
create or replace function public.hr_due_transfer_deactivations()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('request_id', r.id, 'user_id', r.user_id, 'contract_id', r.from_contract_id))
      from hr_change_requests r
     where r.kind = 'transfer' and r.status = 'approved' and r.from_contract_id is not null
       and r.effective_date - 1 < v_today
       and coalesce(r.sync_result->'terminate'->>'ok', 'false') = 'true'
       and coalesce(r.sync_result->>'old_deactivated', 'false') <> 'true'
       and not hr_slip_pending(r.user_id)   -- 源泉徴収票の工程が済んでから（退職の自動停止と同じ待ち）
  ), '[]'::jsonb));
end;
$function$;
revoke all on function public.hr_due_transfer_deactivations() from public, anon, authenticated;
grant execute on function public.hr_due_transfer_deactivations() to service_role;
