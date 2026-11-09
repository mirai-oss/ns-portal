-- 2026-11-09 担当B — 給与・現金手渡しの毎朝の整合チェックを cron に登録（ユーザー方針: 自動化＋ミスはアラート）
-- 【前提】2026-11-09_payroll_finalized_cash_cancel.sql 適用済み（payroll_consistency_check がある）
-- 【内容】毎朝 09:50 JST に payroll_consistency_check(true) を実行。問題が無ければ何も通知しない（静か）。問題があれば Lark/Slack に件数だけ通知
-- 【影響】読み取りと通知のみ。データは変更しない
-- 【rollback】select cron.unschedule('payroll-consistency-check');
do $$
begin
  if exists (select 1 from cron.job where jobname = 'payroll-consistency-check') then perform cron.unschedule('payroll-consistency-check'); end if;
  perform cron.schedule('payroll-consistency-check', '50 0 * * *', $cmd$select public.payroll_consistency_check(true)$cmd$);   -- 00:50 UTC = 09:50 JST
end $$;
select jobname, schedule, active from cron.job where jobname = 'payroll-consistency-check';
