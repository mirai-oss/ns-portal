-- 2026-11-26 Slack の「＋ タスクを作る」を、チーム長（role=TEAM：佐藤・鍋倉・坂本）も使えるようにする（社長依頼）。
-- 画面側（tasks.html の newtask 権限）は既にチーム長以上。Slack 側の2つの関数だけが本部・社長・店長に限られていた。
-- 本番に今ある関数の定義をそのまま読み出し、役職の判定と案内文の2か所だけ置き換えて作り直す（他は一切変えない・権限(grant)も保たれる）。
-- 戻し方: ..._team_ROLLBACK.sql
do $$
declare f record; d text; d2 text; n int := 0;
begin
  for f in select p.oid, p.proname from pg_proc p where p.pronamespace = 'public'::regnamespace
           and p.proname in ('hq_slack_task_create', 'hq_slack_task_create_steps') loop
    d := pg_get_functiondef(f.oid);
    d2 := replace(d, '''CEO'', ''HQ'', ''TENCHO''', '''CEO'', ''HQ'', ''TENCHO'', ''TEAM''');
    d2 := replace(d2, '本部・社長・店長だけです', '本部・社長・チーム長・店長だけです');
    if d2 = d then raise exception '% に置き換え対象が見つかりません（定義が想定と違うため中止）', f.proname; end if;
    execute d2; n := n + 1;
  end loop;
  if n <> 2 then raise exception '対象の関数が2つ見つかりません（%個）', n; end if;
end $$;

-- 確認: 2行とも has_team = true になる
select p.proname, position('''TEAM''' in pg_get_functiondef(p.oid)) > 0 as has_team
from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('hq_slack_task_create', 'hq_slack_task_create_steps') order by 1;
