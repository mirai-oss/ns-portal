-- 2026-11-21 担当B — 勤怠確認（朝のアラート）が「出勤取消」の申請で片づいたとき、アラートも完了（取り消し）にする
--  困りごと: 出勤取消が承認されて勤怠の記録もスマレジも消えたのに、Slack の勤怠確認のカードは「未完了」のまま残り、毎日リマインドが来ていた
--  原因: 出勤取消の申請は、アラートとは別の申請として作られる（アラートの request_id には結びつかない）。承認しても、アラート側の状態が変わる仕組みが無かった
--  やること:
--   ① 出勤取消（kind='delete'）が承認になったら、同じ本人・同じ日・同じ店舗の、まだ「未確認（open）」のアラートを cancelled（完了・取り消し）にする（トリガー）
--      ※ cancelled になれば、毎日のリマインド（open だけが対象）は止まる。Slack のカードを「✅ 完了」に書き換えるのは、Edge Function（attendance-request / slack-interact）の新しい版
--   ② いま残っている分も同じ条件で 1 回だけ直す（承認済みの出勤取消があるのに open のままのアラート）。多すぎる（10 件超）ときは、何も変えずに止まる
--  触るのは sf_attendance_alerts の「状態」だけ。勤怠の記録・申請・スマレジには触れない。
-- 【戻し方】drop trigger sf_attendance_requests_cancel_alert_sync_au on sf_attendance_requests; drop function public.sf_attendance_requests_cancel_alert_sync();
--          （直した分を戻すなら、decision_note が '出勤取消の申請が承認されました' のアラートを status='open' に）
begin;

create or replace function public.sf_attendance_requests_cancel_alert_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'delete' and new.status = 'approved' and old.status is distinct from 'approved' then
    begin
      update sf_attendance_alerts
         set status = 'cancelled', decided_by = new.decided_by, decided_at = coalesce(new.decided_at, now()),
             decision_note = '出勤取消の申請が承認されました', updated_at = now()
       where user_id = new.user_id and work_date = new.work_date and store_id = new.store_id and status = 'open' and request_id is null;
    exception when others then
      raise warning 'sf_attendance_requests_cancel_alert_sync: %', sqlerrm;   -- アラートの更新に失敗しても、申請の承認は止めない
    end;
  end if;
  return null;
end $$;

drop trigger if exists sf_attendance_requests_cancel_alert_sync_au on sf_attendance_requests;
create trigger sf_attendance_requests_cancel_alert_sync_au after update on sf_attendance_requests
  for each row execute function public.sf_attendance_requests_cancel_alert_sync();

-- ② いま残っている分を 1 回だけ直す
do $$
declare n int;
begin
  with t as (
    update sf_attendance_alerts a
       set status = 'cancelled', decided_by = r.decided_by, decided_at = coalesce(r.decided_at, now()),
           decision_note = '出勤取消の申請が承認されました', updated_at = now()
      from sf_attendance_requests r
     where r.kind = 'delete' and r.status = 'approved'
       and a.user_id = r.user_id and a.work_date = r.work_date and a.store_id = r.store_id
       and a.status = 'open' and a.request_id is null
    returning a.id)
  select count(*) into n from t;
  if n > 10 then raise exception '停止: 直す対象が % 件あります（想定は数件）。何も変えていません', n; end if;
  raise notice '直したアラート: % 件', n;
end $$;

commit;
