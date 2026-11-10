-- 2026-11-10 担当B 【案b・未適用・ユーザー判断待ち】2026-10 の「給料確定の印」を外す（案aなら適用しない）
-- 影響: 現金手渡し画面から2026-10分（8名・サイン記録あり）が消える。データは残る。給料確定ボタンを2026-10で押すと再表示。
--   ※2026-10は給料確定ボタン未使用・振込/本部タスクはテンプレ由来。ボタンを押すと既存タスクが完了済みなら「紐づけも作成もしない」警告になる
-- 戻し方: insert into payroll_finalized(year_month, corporation_id) select '2026-10', sc.corporation_id from smaregi_contracts sc where sc.is_default on conflict do nothing;
delete from payroll_finalized where year_month = '2026-10' and finalized_by is null;
select year_month, count(*) from payroll_finalized group by year_month order by 1;
