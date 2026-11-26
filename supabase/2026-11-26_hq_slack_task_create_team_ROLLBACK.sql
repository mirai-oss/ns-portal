-- チーム長の Slack タスク作成を元に戻す
do $$
declare f record; d text;
begin
  for f in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('hq_slack_task_create', 'hq_slack_task_create_steps') loop
    d := replace(pg_get_functiondef(f.oid), '''CEO'', ''HQ'', ''TENCHO'', ''TEAM''', '''CEO'', ''HQ'', ''TENCHO''');
    d := replace(d, '本部・社長・チーム長・店長だけです', '本部・社長・店長だけです');
    execute d;
  end loop;
end $$;
